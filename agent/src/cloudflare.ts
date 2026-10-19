/**
 * Cloudflare deploys: Workers (static assets, plain JavaScript, or anything wrangler builds) and Pages (direct
 * upload). Mirrors what wrangler sends, so deployments behave the same as `wrangler deploy` / `wrangler pages deploy`.
 *
 * Static files and plain-JavaScript Workers upload straight from the app. Workers that need a build step
 * (TypeScript, npm packages, Durable Object migrations) and Pages Functions go through wrangler in the Linux
 * container, which has npm.
 */

import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from "node:fs";
import { basename, dirname, extname, isAbsolute, join, normalize, relative, resolve, sep } from "node:path";
import { blake3 } from "@noble/hashes/blake3.js";
import { bytesToHex } from "@noble/hashes/utils.js";
import mime from "mime-types";
import { parse as parseToml } from "smol-toml";

export interface CloudflareAccount {
	id: string;
	name: string;
}

/** Line output, plus an optional channel for structured progress (see integrations.ts). */
type Log = ((line: string) => void) & { ci?: (snapshot: any) => void };

/** Runs a command, resolving with its output (integrations.ts `run`). */
type Run = (cmd: string, args: string[], opts: { cwd: string; log?: Log }) => Promise<string>;

const API = "https://api.cloudflare.com/client/v4";
/** Compatibility date for Workers whose config doesn't set one. */
const COMPATIBILITY_DATE = "2025-09-01";
const MAX_FILE = 25 * 1024 * 1024;
const MAX_FILES = 20_000;
/** Never uploaded as site files. Dotfiles are skipped too (secrets like .env, .dev.vars), except .well-known. */
const SKIP = new Set(["node_modules"]);
/** Pages reads these from the upload form instead of the file list. */
const PAGES_SPECIAL = new Set(["_worker.js", "_redirects", "_headers", "_routes.json", "functions"]);

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export class Cloudflare {
	constructor(
		private readonly token: string,
		private readonly accountId: string,
	) {}

	// ---------------------------------------------------------------------------
	// API

	static async request(token: string, path: string, init: RequestInit = {}, auth = `Bearer ${token}`) {
		const res = await fetch(path.startsWith("http") ? path : `${API}${path}`, {
			// A minute, plus time for the body at a slow 25 KB/s: big uploads on poor mobile data still finish,
			// a stalled connection still ends.
			signal: AbortSignal.timeout(Math.round(60_000 + (bodySize(init.body) / 25_000) * 1000)),
			...init,
			headers: {
				Authorization: auth,
				...(typeof init.body === "string" ? { "Content-Type": "application/json" } : {}),
				...init.headers,
			},
		});
		const body = (await res.json().catch(() => null)) as any;
		if (!res.ok || body?.success === false) {
			const error = body?.errors?.[0];
			const code = error?.code as number | undefined;
			const raw = `${error?.message ?? res.statusText} (${code ?? res.status})`;
			// The usual causes, in words: a Global API Key pasted instead of a token, or a token missing permissions.
			// Upload tokens (auth not from this token) report their own expiry, handled by the caller.
			const ownToken = auth === `Bearer ${token}`;
			const message =
				ownToken && (code === 6003 || code === 6111 || code === 9106 || code === 9109 || code === 1000 || res.status === 401)
					? `Cloudflare didn't accept this token. Paste an API token (not the Global API Key) in Accounts. [${raw}]`
					: ownToken && (code === 10000 || res.status === 403)
						? `This Cloudflare token isn't allowed to do that. It needs Workers Scripts: Edit and Cloudflare Pages: Edit (the "Edit Cloudflare Workers" template). [${raw}]`
						: `Cloudflare: ${raw}`;
			const err = new Error(message);
			(err as any).status = res.status;
			(err as any).code = error?.code;
			throw err;
		}
		return body?.result as any;
	}

	private api(path: string, init: RequestInit = {}) {
		return Cloudflare.request(this.token, path, init);
	}

	/** The accounts a token can reach; also proves the token works. */
	static async accounts(token: string): Promise<CloudflareAccount[]> {
		const list = (await Cloudflare.request(token, "/accounts?per_page=50")) as any[];
		if (!list?.length) {
			throw new Error(
				"This token can't see any Cloudflare account. Create it with the \"Edit Cloudflare Workers\" template, " +
					"or give it Workers Scripts: Edit and Cloudflare Pages: Edit.",
			);
		}
		return list.map((a) => ({ id: a.id, name: a.name }));
	}

	// ---------------------------------------------------------------------------
	// Workers

	/**
	 * Deploys [dir] as a Worker. With a wrangler config (wrangler.jsonc/json/toml, in [dir] or the project [root]) its
	 * name, code, assets and bindings are used; without one the folder is served as static assets.
	 */
	async deployWorker(
		dir: string,
		root: string,
		options: { name?: string; spa?: boolean },
		log: Log,
		container: { run: Run; available: boolean },
	): Promise<{ url: string | null }> {
		const config = readWranglerConfig(dir) ?? (dir === root ? null : readWranglerConfig(root));
		// The name typed in the app (only sent when changed), else the config's as written, else the project folder's.
		const name = options.name
			? sanitizeName(options.name)
			: config?.name && WORKER_NAME.test(config.name)
				? config.name
				: sanitizeName(config?.name || basename(root));
		const report = progress(log, `Workers · ${name}`, `https://dash.cloudflare.com/${this.accountId}/workers/services/view/${name}`);

		// Anything the direct upload can't do exactly as wrangler would goes to wrangler, rather than half-deploying.
		const unsupported = config ? Object.keys(config).filter((k) => !DIRECT_KEYS.has(k)) : [];
		let main: string | null = null;
		if (config?.main) {
			main = resolve(config.dir, config.main);
			if (!existsSync(main)) throw new Error(`The Worker's main file is missing: ${config.main}`);
		}
		const needsBuild = (main !== null && !plainModules(main)) || unsupported.length > 0;
		if (config && needsBuild) {
			if (!container.available) {
				const why = unsupported.length
					? `its config uses ${unsupported.join(", ")}`
					: "it needs building (TypeScript, JSX or npm packages)";
				throw new Error(
					`This Worker has to be deployed with wrangler: ${why}. ` +
						"Install the Linux container and Node.js in it (Settings > Linux container), then deploy again.",
				);
			}
			report("in_progress");
			try {
				const out = await container.run(
					"box",
					// The config's own name stays wrangler's business, unless one was typed (or there is none).
					["-c", `npx --yes wrangler@4 deploy${options.name || !config.name ? ` --name ${name}` : ""}`],
					{ cwd: config.dir, log },
				);
				report("success");
				return { url: out.match(/https:\/\/\S+\.workers\.dev\S*/)?.[0] ?? null };
			} catch (e) {
				report("failure");
				throw e;
			}
		}

		report("queued");
		try {
			// The config's assets folder; else the chosen folder, unless that is just the Worker's own project.
			const assetsDir = config?.assets?.directory
				? inside(root, resolve(config.dir, config.assets.directory), "The assets folder")
				: config?.main && dir === config.dir
					? null
					: dir;
			if (assetsDir && !config?.assets?.directory) notSourceFolder(assetsDir, root);
			if (assetsDir) inside(root, assetsDir, "The folder to deploy");
			let jwt: string | null = null;
			if (assetsDir) {
				if (!existsSync(assetsDir)) throw new Error(`No such assets folder: ${relative(dir, assetsDir) || "."}`);
				jwt = await this.uploadWorkerAssets(name, assetsDir, log);
			}
			report("in_progress");

			const form = new FormData();
			const metadata: Record<string, any> = {
				compatibility_date: config?.compatibility_date ?? COMPATIBILITY_DATE,
				...(config?.compatibility_flags && { compatibility_flags: config.compatibility_flags }),
				...(config?.observability !== undefined && { observability: config.observability }),
			};
			if (jwt) {
				const headers = assetsDir && readOptional(join(assetsDir, "_headers"));
				const redirects = assetsDir && readOptional(join(assetsDir, "_redirects"));
				metadata.assets = {
					jwt,
					config: {
						html_handling: config?.assets?.html_handling,
						not_found_handling:
							config?.assets?.not_found_handling ?? (options.spa ? "single-page-application" : undefined),
						run_worker_first: config?.assets?.run_worker_first,
						...(headers && { _headers: headers }),
						...(redirects && { _redirects: redirects }),
					},
				};
			}
			if (config?.main && main) {
				const modules = plainModules(main)!;
				for (const file of modules) inside(root, file, "The Worker's code");
				const moduleRoot = dirname(main);
				metadata.main_module = basename(main);
				metadata.bindings = workerBindings(config);
				// Secrets are set separately (wrangler secret put); never drop them on deploy, as wrangler doesn't.
				// keep_vars keeps the dashboard's variables too.
				metadata.keep_bindings = ["secret_text", "secret_key", ...(config.keep_vars ? ["plain_text", "json"] : [])];
				log(`Uploading ${modules.length} module${modules.length === 1 ? "" : "s"}…`);
				for (const file of modules) {
					const part = relative(moduleRoot, file).split(sep).join("/");
					form.set(part, new File([readFileSync(file)], part, { type: "application/javascript+module" }));
				}
			}
			form.set("metadata", JSON.stringify(metadata));
			log(`Deploying ${name}…`);
			await this.api(`/accounts/${this.accountId}/workers/scripts/${name}?excludeScript=true`, {
				method: "PUT",
				body: form,
			});

			// Serve it on workers.dev, as wrangler does by default. Like wrangler, look up the account's subdomain
			// first: a new account may not have one yet (10007), and the Worker is deployed either way.
			let url: string | null = null;
			if (config?.workers_dev !== false) {
				// The Worker is live by now: a hiccup here is reported, not turned into a failed deploy.
				let subdomain: string | null = null;
				let lookupFailed = false;
				try {
					subdomain = (await retry(() => this.api(`/accounts/${this.accountId}/workers/subdomain`)))?.subdomain ?? null;
				} catch (e) {
					if ((e as any).code !== 10007) {
						lookupFailed = true;
						log(`Deployed, but its workers.dev address couldn't be set up: ${(e as Error).message}`);
					}
				}
				if (subdomain) {
					await retry(() =>
						this.api(`/accounts/${this.accountId}/workers/scripts/${name}/subdomain`, {
							method: "POST",
							body: JSON.stringify({
								enabled: true,
								// Unset leaves it to Cloudflare, as wrangler does.
								...(config?.preview_urls !== undefined && { previews_enabled: config.preview_urls }),
							}),
						}),
					);
					url = `https://${name}.${subdomain}.workers.dev`;
				} else if (!lookupFailed) {
					log(
						"Deployed. This account has no workers.dev subdomain yet: pick one in the Cloudflare dashboard (Workers & Pages), then deploy again to get a URL.",
					);
				}
			}
			report("success");
			if (url) log(`Live at ${url}`);
			return { url };
		} catch (e) {
			report("failure");
			throw e;
		}
	}

	/** Uploads what changed of [dir] for Worker [name]; returns the completion token for the script upload. */
	private async uploadWorkerAssets(name: string, dir: string, log: Log): Promise<string> {
		const ignored = assetsIgnore(dir);
		const files = listFiles(dir, (rel) => rel === "_headers" || rel === "_redirects" || ignored(rel));
		if (files.length === 0) throw new Error("Nothing to deploy: the folder is empty");
		// Like wrangler: a Pages-style worker in the assets would be served to anyone as plain text.
		if (files.some((f) => f === "_worker.js" || f.startsWith("_worker.js/"))) {
			throw new Error(
				"The folder has a _worker.js, which Workers would serve publicly as a file. Deploy it to Pages instead, or list _worker.js in .assetsignore.",
			);
		}
		log(`Hashing ${files.length} files…`);
		const manifest: Record<string, { hash: string; size: number }> = {};
		const byHash = new Map<string, string>();
		for (const rel of files) {
			const path = join(dir, rel);
			const hash = hashFile(path);
			manifest[`/${rel}`] = { hash, size: statSync(path).size };
			byHash.set(hash, path);
		}
		const session = await this.api(`/accounts/${this.accountId}/workers/scripts/${name}/assets-upload-session`, {
			method: "POST",
			body: JSON.stringify({ manifest }),
		});
		const buckets: string[][] = session.buckets ?? [];
		const total = buckets.flat().length;
		if (total === 0) {
			log("No changed files to upload.");
			return session.jwt;
		}
		log(`Uploading ${total} new or changed file${total === 1 ? "" : "s"} (${files.length - total} unchanged)…`);
		let jwt: string = session.jwt;
		let done = 0;
		// Some accounts are switched to one file per request (a claim in the upload token), as wrangler honours.
		if (jwtClaim(session.jwt, "wrangler_single_asset_uploads") === true) {
			for (const hash of buckets.flat()) {
				const path = byHash.get(hash);
				if (!path) throw new Error("Cloudflare asked for a file that isn't in the folder");
				const result = await retry(() =>
					Cloudflare.request(
						this.token,
						`/accounts/${this.accountId}/workers/assets/upload/${hash}`,
						{ method: "POST", body: readFileSync(path), headers: { "Content-Type": contentType(path) ?? "application/null" } },
						`Bearer ${session.jwt}`,
					),
				);
				if (result?.jwt) jwt = result.jwt;
				done++;
				if (done % 10 === 0 || done === total) log(`  ${done}/${total}`);
			}
			return jwt;
		}
		for (const bucket of buckets) {
			const form = new FormData();
			for (const hash of bucket) {
				const path = byHash.get(hash);
				if (!path) throw new Error("Cloudflare asked for a file that isn't in the folder");
				form.append(
					hash,
					new File([readFileSync(path).toString("base64")], hash, { type: contentType(path) ?? "application/null" }),
					hash,
				);
			}
			const result = await retry(() =>
				Cloudflare.request(this.token, `/accounts/${this.accountId}/workers/assets/upload?base64=true`, {
					method: "POST",
					body: form,
				}, `Bearer ${session.jwt}`),
			);
			if (result?.jwt) jwt = result.jwt;
			done += bucket.length;
			log(`  ${done}/${total}`);
		}
		return jwt;
	}

	// ---------------------------------------------------------------------------
	// Pages

	/** Deploys [dir] to Pages project [project], created on first deploy. */
	async deployPages(
		dir: string,
		root: string,
		options: { project?: string; preview?: boolean },
		log: Log,
		container: { run: Run; available: boolean },
	): Promise<{ url: string | null }> {
		const name = sanitizeName(options.project || basename(root));
		const report = progress(log, `Pages · ${name}`, `https://dash.cloudflare.com/${this.accountId}/pages/view/${name}`);
		report("queued");
		try {
			let project: any;
			try {
				project = await this.api(`/accounts/${this.accountId}/pages/projects/${name}`);
			} catch (e) {
				if ((e as any).status !== 404) throw e;
				log(`Creating Pages project ${name}…`);
				project = await this.api(`/accounts/${this.accountId}/pages/projects`, {
					method: "POST",
					body: JSON.stringify({ name, production_branch: "main" }),
				});
			}
			const branch = options.preview ? "preview" : project.production_branch || "main";

			// Functions, a _worker.js folder, or a _worker.js that imports packages need wrangler to bundle them.
			const worker = join(dir, "_worker.js");
			const workerIsDir = existsSync(worker) && statSync(worker).isDirectory();
			const workerModules = existsSync(worker) && !workerIsDir ? plainModules(worker) : [];
			const functions = existsSync(join(root, "functions"));
			// Before wrangler too: wrangler pages publishes dotfiles and all.
			notSourceFolder(dir, root);
			inside(root, dir, "The folder to deploy");
			if (functions || workerIsDir || workerModules === null) {
				if (!container.available && (workerIsDir || workerModules === null)) {
					throw new Error(
						"This site's _worker.js has to be bundled by wrangler (it is a folder or imports packages). " +
							"Install the Linux container and Node.js in it (Settings > Linux container), then deploy again.",
					);
				}
				if (container.available) {
					report("in_progress");
					const out = await container.run(
						"box",
						[
							"-c",
							`npx --yes wrangler@4 pages deploy ${shellQuote(relative(root, dir) || ".")} --project-name ${name} --branch ${shellQuote(branch)} --commit-dirty=true`,
						],
						{ cwd: root, log },
					);
					report("success");
					const url = options.preview ? out.match(/https:\/\/\S+\.pages\.dev\S*/)?.[0] ?? null : `https://${project.subdomain}`;
					if (url) log(`Live at ${url}`);
					return { url };
				}
				log("Note: the functions folder is skipped; deploying it needs wrangler in the Linux container.");
			}

			const files = listFiles(dir, (rel) => PAGES_SPECIAL.has(rel.split("/")[0]));
			if (files.length === 0) throw new Error("Nothing to deploy: the folder is empty");
			// The upload token is short-lived: fetch a fresh one when it has expired or is refused, as wrangler does.
			let jwt: string = (await this.api(`/accounts/${this.accountId}/pages/projects/${name}/upload-token`)).jwt;
			const freshJwt = async () => {
				jwt = (await this.api(`/accounts/${this.accountId}/pages/projects/${name}/upload-token`)).jwt;
			};
			log(`Hashing ${files.length} files…`);
			const entries = files.map((rel) => {
				const path = join(dir, rel);
				return { rel, path, hash: hashFile(path), size: statSync(path).size };
			});
			const pages = (path: string, body: unknown) =>
				retry(async () => {
					if (jwtExpired(jwt)) await freshJwt();
					const call = () =>
						Cloudflare.request(this.token, `/pages/assets/${path}`, { method: "POST", body: JSON.stringify(body) }, `Bearer ${jwt}`);
					try {
						return await call();
					} catch (e) {
						if ((e as any).code !== 8000013 && (e as any).status !== 401) throw e;
						await freshJwt();
						return await call();
					}
				});
			const missing = new Set<string>(await pages("check-missing", { hashes: entries.map((e) => e.hash) }));
			const upload = entries.filter((e) => missing.has(e.hash));
			if (upload.length) {
				log(`Uploading ${upload.length} new or changed file${upload.length === 1 ? "" : "s"} (${entries.length - upload.length} unchanged)…`);
			} else {
				log("No changed files to upload.");
			}
			let done = 0;
			for (const bucket of bucketsOf(upload)) {
				await pages(
					"upload",
					bucket.map((e) => ({
						key: e.hash,
						value: readFileSync(e.path).toString("base64"),
						metadata: { contentType: contentType(e.path) ?? "application/octet-stream" },
						base64: true,
					})),
				);
				done += bucket.length;
				log(`  ${done}/${upload.length}`);
			}
			await pages("upsert-hashes", { hashes: entries.map((e) => e.hash) }).catch(() => {});

			report("in_progress");
			const form = new FormData();
			form.append("manifest", JSON.stringify(Object.fromEntries(entries.map((e) => [`/${e.rel}`, e.hash]))));
			form.append("branch", branch);
			for (const special of ["_headers", "_redirects"]) {
				const text = readOptional(join(dir, special));
				if (text) form.append(special, new File([text], special));
			}
			if (workerModules?.length) {
				log("Uploading _worker.js…");
				const bundle = new FormData();
				bundle.set("metadata", JSON.stringify({ main_module: "_worker.js" }));
				for (const file of workerModules) {
					const part = relative(dir, file).split(sep).join("/");
					bundle.set(part, new File([readFileSync(file)], part, { type: "application/javascript+module" }));
				}
				form.append("_worker.bundle", new File([await new Response(bundle).blob()], "_worker.bundle"));
				const routes = readOptional(join(dir, "_routes.json"));
				if (routes) form.append("_routes.json", new File([routes], "_routes.json"));
			}
			log(`Creating deployment on ${branch}…`);
			let deployment = await this.api(`/accounts/${this.accountId}/pages/projects/${name}/deployments`, {
				method: "POST",
				body: form,
			});
			const started = Date.now();
			const dashboard = `https://dash.cloudflare.com/${this.accountId}/pages/view/${name}/${deployment.id}`;
			for (;;) {
				const stage = deployment.latest_stage;
				if (stage?.status === "failure" || stage?.status === "canceled") {
					throw new Error(`The Pages deployment ${stage.status === "failure" ? "failed" : "was canceled"} at ${stage.name}. Details: ${dashboard}`);
				}
				if (stage?.name === "deploy" && stage.status === "success") break;
				if (Date.now() - started > 5 * 60_000) {
					throw new Error(`The Pages deployment is still running after 5 minutes. Check it here: ${dashboard}`);
				}
				await sleep(2000);
				try {
					deployment = await this.api(`/accounts/${this.accountId}/pages/projects/${name}/deployments/${deployment.id}`);
				} catch {
					// A blip while polling; the deployment itself carries on.
				}
			}
			report("success");
			const alias = (deployment.aliases as string[] | undefined)?.find((a) => a.endsWith(".pages.dev"));
			const url = options.preview ? (alias ?? deployment.url) : `https://${project.subdomain}`;
			log(`Live at ${url}`);
			return { url };
		} catch (e) {
			report("failure");
			throw e;
		}
	}
}

// ---------------------------------------------------------------------------
// Helpers

/** The hash Cloudflare keys static files by (wrangler's hashFile): BLAKE3 of base64 content plus extension. */
export function hashFile(path: string) {
	const data = readFileSync(path).toString("base64") + extname(path).slice(1);
	return bytesToHex(blake3(new TextEncoder().encode(data))).slice(0, 32);
}

function contentType(path: string): string | undefined {
	const type = mime.lookup(path);
	if (!type) return undefined;
	return type.startsWith("text/") && !type.includes("charset") ? `${type}; charset=utf-8` : type;
}

/** Files under [dir] as "/"-separated relative paths, skipping VCS and dependency folders and [skip]. */
export function listFiles(dir: string, skip: (rel: string) => boolean = () => false): string[] {
	const out: string[] = [];
	const visit = (sub: string) => {
		for (const entry of readdirSync(join(dir, sub), { withFileTypes: true })) {
			if (SKIP.has(entry.name) || (entry.name.startsWith(".") && entry.name !== ".well-known")) continue;
			const rel = sub ? `${sub}/${entry.name}` : entry.name;
			if (skip(rel)) continue;
			if (entry.isDirectory()) visit(rel);
			else if (entry.isFile()) {
				if (statSync(join(dir, rel)).size > MAX_FILE) throw new Error(`${rel} is over Cloudflare's 25 MiB file limit`);
				out.push(rel);
				if (out.length > MAX_FILES) throw new Error("Too many files to deploy (over 20,000). Is this the build output folder?");
			}
		}
	};
	visit("");
	return out;
}

/** Up to 40 MB and 2,000 files per Pages upload request, like wrangler. */
function bucketsOf<T extends { size: number }>(files: T[]): T[][] {
	const buckets: T[][] = [];
	let current: T[] = [];
	let size = 0;
	for (const f of [...files].sort((a, b) => b.size - a.size)) {
		// Base64 grows files by a third.
		const encoded = Math.ceil(f.size / 3) * 4;
		if (current.length && (size + encoded > 40 * 1024 * 1024 || current.length >= 2000)) {
			buckets.push(current);
			current = [];
			size = 0;
		}
		current.push(f);
		size += encoded;
	}
	if (current.length) buckets.push(current);
	return buckets;
}

async function retry<T>(job: () => Promise<T>, attempts = 4): Promise<T> {
	for (let i = 0; ; i++) {
		try {
			return await job();
		} catch (e) {
			const status = (e as any).status as number | undefined;
			const transient = status === undefined || status === 429 || status >= 500;
			if (!transient || i >= attempts - 1) throw e;
			await sleep(2 ** i * 1000);
		}
	}
}

/**
 * [path], refused when it points outside the project [root] (a config could otherwise reach ~/.ssh). Symlinks are
 * resolved first, so a linked folder can't lead outside either.
 */
export function inside(root: string, path: string, what: string) {
	const real = (p: string) => {
		try {
			return realpathSync(p);
		} catch {
			return resolve(p);
		}
	};
	const rel = relative(real(root), real(path));
	if (rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) throw new Error(`${what} is outside the project folder`);
	return path;
}

/** Bytes in a request body, for its timeout. */
function bodySize(body: unknown): number {
	if (typeof body === "string") return Buffer.byteLength(body);
	if (body instanceof Uint8Array) return body.byteLength;
	if (body instanceof FormData) {
		let size = 0;
		for (const [, v] of body.entries()) size += typeof v === "string" ? Buffer.byteLength(v) : v.size;
		return size;
	}
	return 0;
}

/** Refuses to publish a project's own source folder (package.json, no wrangler config) as a static site. */
function notSourceFolder(dir: string, root: string) {
	if (resolve(dir) === resolve(root) && existsSync(join(root, "package.json"))) {
		throw new Error(
			"This is the project's source folder, not its build output, and publishing it would expose the source. " +
				"Set the folder to the build output (dist, build or out), or turn on Build first.",
		);
	}
}

/** The patterns in [dir]/.assetsignore (gitignore syntax), as wrangler applies them. */
export function assetsIgnore(dir: string): (rel: string) => boolean {
	const text = readOptional(join(dir, ".assetsignore"));
	if (!text) return () => false;
	const rules = text
		.split(/\r?\n/)
		.map((l) => l.replace(/(?<!\\)\s+$/, ""))
		.filter((l) => l && !l.startsWith("#"))
		.map((line) => {
			const negate = line.startsWith("!");
			// "\#" and "\!" stand for a literal # or ! at the start.
			let pattern = negate ? line.slice(1) : line.replace(/^\\([#!])/, "$1");
			const dirOnly = pattern.endsWith("/");
			pattern = pattern.replace(/\/+$/, "");
			const anchored = pattern.includes("/");
			pattern = pattern.replace(/^\//, "");
			let re = "";
			for (let i = 0; i < pattern.length; i++) {
				const c = pattern[i];
				if (c === "\\" && i + 1 < pattern.length) {
					re += pattern[++i].replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
				} else if (c === "*" && pattern[i + 1] === "*") {
					re += pattern[i + 2] === "/" ? "(?:.*/)?" : ".*";
					i += pattern[i + 2] === "/" ? 2 : 1;
				} else if (c === "*") re += "[^/]*";
				else if (c === "?") re += "[^/]";
				else if (c === "[" && pattern.indexOf("]", i + 2) > 0) {
					// A character class, [!abc] negated as in git.
					const close = pattern.indexOf("]", i + 2);
					const body = pattern.slice(i + 1, close).replace(/^!/, "^").replace(/\\/g, "\\\\");
					re += `[${body}]`;
					i = close;
				} else re += c.replace(/[.+^${}()|[\]\\]/g, "\\$&");
			}
			return { negate, dirOnly, regex: new RegExp(`^${anchored ? "" : "(?:.*/)?"}${re}$`) };
		});
	const match = (path: string, isDir: boolean) => {
		let ignored = false;
		for (const r of rules) if ((!r.dirOnly || isDir) && r.regex.test(path)) ignored = !r.negate;
		return ignored;
	};
	// As in git: inside an ignored folder nothing can be brought back.
	return (rel) => {
		const parts = rel.split("/");
		for (let i = 1; i < parts.length; i++) if (match(parts.slice(0, i).join("/"), true)) return true;
		// Files under an ignored folder are caught above, so a path is matched here as a file.
		return match(rel, false);
	};
}

/** A claim from a JWT's payload, or undefined when it can't be read. */
function jwtClaim(jwt: string, claim: string): unknown {
	try {
		return JSON.parse(Buffer.from(jwt.split(".")[1], "base64url").toString("utf8"))[claim];
	} catch {
		return undefined;
	}
}

/** Whether a JWT's exp has passed (or will within a minute). Unreadable tokens count as fresh. */
function jwtExpired(jwt: string) {
	const exp = jwtClaim(jwt, "exp");
	return typeof exp === "number" && exp * 1000 < Date.now() + 60_000;
}

function readOptional(path: string) {
	try {
		return statSync(path).isFile() ? readFileSync(path, "utf8") : null;
	} catch {
		return null;
	}
}

/** Workers and Pages names: lowercase letters, digits and dashes, up to 58 characters (Pages' limit). */
export function sanitizeName(s: string) {
	return (
		s
			.toLowerCase()
			.replace(/[^a-z0-9-]+/g, "-")
			.replace(/^-+|-+$/g, "")
			.slice(0, 58)
			.replace(/-+$/, "") || "site"
	);
}

function shellQuote(s: string) {
	return `'${s.replace(/'/g, `'\\''`)}'`;
}

/** Reports one run to the deploy log's progress panel. */
function progress(log: Log, name: string, url: string) {
	const id = `${Date.now()}`;
	return (state: "queued" | "in_progress" | "success" | "failure") =>
		log.ci?.({
			provider: "cloudflare",
			runs: [
				{
					id,
					name,
					status: state === "success" || state === "failure" ? "completed" : state,
					conclusion: state === "success" || state === "failure" ? state : null,
					url,
					jobs: [],
				},
			],
		});
}

// ---------------------------------------------------------------------------
// wrangler config

/** Config keys the direct upload handles exactly like wrangler; any other key sends the deploy to wrangler. */
const DIRECT_KEYS = new Set([
	"dir",
	"$schema",
	"name",
	"main",
	"account_id",
	"compatibility_date",
	"compatibility_flags",
	"workers_dev",
	"preview_urls",
	"assets",
	"vars",
	"kv_namespaces",
	"d1_databases",
	"r2_buckets",
	"ai",
	// Local development and environments other than the top level don't affect this deploy.
	"dev",
	"env",
	"send_metrics",
	"keep_vars",
	// Passed through as is, as wrangler does.
	"observability",
]);

/** Names wrangler accepts for a Worker; a config's name that fits is used exactly as written. */
const WORKER_NAME = /^[a-z0-9_][a-z0-9-_]*$/;

export interface WranglerConfig {
	/** The folder the config file is in; its paths are relative to it. */
	dir: string;
	name?: string;
	main?: string;
	compatibility_date?: string;
	compatibility_flags?: string[];
	workers_dev?: boolean;
	preview_urls?: boolean;
	keep_vars?: boolean;
	observability?: unknown;
	assets?: {
		directory?: string;
		binding?: string;
		html_handling?: string;
		not_found_handling?: string;
		run_worker_first?: boolean | string[];
	};
	vars?: Record<string, unknown>;
	kv_namespaces?: { binding: string; id: string }[];
	d1_databases?: { binding: string; database_id: string }[];
	r2_buckets?: { binding: string; bucket_name: string }[];
	ai?: { binding: string };
	build?: unknown;
	durable_objects?: unknown;
	migrations?: unknown;
}

/** wrangler.jsonc, wrangler.json or wrangler.toml in [dir], if any. */
export function readWranglerConfig(dir: string): WranglerConfig | null {
	for (const file of ["wrangler.jsonc", "wrangler.json", "wrangler.toml"]) {
		const path = join(dir, file);
		if (!existsSync(path)) continue;
		const text = readFileSync(path, "utf8");
		try {
			const config = file.endsWith(".toml") ? parseToml(text) : JSON.parse(stripJsonComments(text));
			return { ...(config as object), dir } as WranglerConfig;
		} catch (e) {
			throw new Error(`Could not read ${file}: ${(e as Error).message}`);
		}
	}
	return null;
}

/** JSONC to JSON: drops comments and trailing commas, leaving strings alone. */
export function stripJsonComments(text: string) {
	let out = "";
	for (let i = 0; i < text.length; i++) {
		const c = text[i];
		if (c === '"') {
			const start = i;
			for (i++; i < text.length && text[i] !== '"'; i++) if (text[i] === "\\") i++;
			out += text.slice(start, i + 1);
		} else if (c === "/" && text[i + 1] === "/") {
			while (i < text.length && text[i] !== "\n") i++;
			out += "\n";
		} else if (c === "/" && text[i + 1] === "*") {
			i = text.indexOf("*/", i + 2);
			if (i < 0) break;
			i++;
		} else {
			out += c;
		}
	}
	return out.replace(/,(\s*[}\]])/g, "$1");
}

function workerBindings(config: WranglerConfig) {
	const bindings: Record<string, unknown>[] = [];
	for (const [name, value] of Object.entries(config.vars ?? {})) {
		bindings.push(typeof value === "string" ? { name, type: "plain_text", text: value } : { name, type: "json", json: value });
	}
	for (const kv of config.kv_namespaces ?? []) bindings.push({ name: kv.binding, type: "kv_namespace", namespace_id: kv.id });
	for (const db of config.d1_databases ?? []) bindings.push({ name: db.binding, type: "d1", id: db.database_id });
	for (const r2 of config.r2_buckets ?? []) bindings.push({ name: r2.binding, type: "r2_bucket", bucket_name: r2.bucket_name });
	if (config.ai?.binding) bindings.push({ name: config.ai.binding, type: "ai" });
	if (config.assets?.binding) bindings.push({ name: config.assets.binding, type: "assets" });
	return bindings;
}

/** [source] without line and block comments; strings and template literals are left alone. */
function stripComments(source: string) {
	let out = "";
	for (let i = 0; i < source.length; i++) {
		const c = source[i];
		if (c === '"' || c === "'" || c === "`") {
			const start = i;
			for (i++; i < source.length && source[i] !== c; i++) if (source[i] === "\\") i++;
			out += source.slice(start, i + 1);
		} else if (c === "/" && source[i + 1] === "/") {
			while (i < source.length && source[i] !== "\n") i++;
			out += "\n";
		} else if (c === "/" && source[i + 1] === "*") {
			const end = source.indexOf("*/", i + 2);
			i = end < 0 ? source.length : end + 1;
			out += " ";
		} else out += c;
	}
	return out;
}

/** [source] (comments already stripped) with the contents of strings and template literals blanked. */
function blankStrings(source: string) {
	return source.replace(/(["'`])(?:\\.|(?!\1)[^\\])*\1/gs, (m) => m[0] + " ".repeat(Math.max(0, m.length - 2)) + m[0]);
}

const IMPORT = /(?:^|[\s;}])(?:import|export)\s*(?:[^'"`;]*?\s*from\s*)?["']([^"']+)["']|import\(\s*["']([^"']+)["']\s*\)/g;

/**
 * The Worker's modules when it is plain JavaScript importing only its own files (and the cloudflare: / node:
 * builtins), so it can be uploaded as is. Null when it needs a build: TypeScript, JSX or npm packages.
 */
export function plainModules(main: string): string[] | null {
	const seen = new Set<string>();
	const root = dirname(main);
	const visit = (file: string): boolean => {
		if (seen.has(file)) return true;
		if (!/\.(m?js)$/.test(file) || !existsSync(file)) return false;
		seen.add(file);
		const source = stripComments(readFileSync(file, "utf8"));
		// CommonJS and computed imports can't be followed: leave those to a bundler. Strings are blanked first, so
		// a mention of require() in text doesn't count.
		if (/(^|[^.\w$])require\s*\(|(^|[^.\w$])import\s*\(\s*[^"'\s]/.test(blankStrings(source))) return false;
		for (const m of source.matchAll(IMPORT)) {
			const spec = m[1] ?? m[2];
			if (/^(cloudflare|node):/.test(spec)) continue;
			if (!spec.startsWith(".")) return false;
			const target = normalize(resolve(dirname(file), spec));
			// Modules are uploaded relative to the entry's folder.
			if (relative(root, target).startsWith("..")) return false;
			if (!visit(target)) return false;
		}
		return true;
	};
	return visit(resolve(main)) ? [...seen] : null;
}
