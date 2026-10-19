/**
 * GitHub sync: chats, projects and app settings kept in a private repository
 * (<login>/andropi-sync) so another phone can pick them up after signing in.
 *
 * Each sync pulls first, then mirrors this phone into the repository and
 * pushes. Items another phone added are copied in; items this phone deleted
 * since the last sync are not brought back (synced.json remembers what was
 * there). For existing items this phone wins, except chats, which only ever
 * grow, so the longer copy wins.
 *
 * Projects with a git remote are recorded (remote + branch) and cloned on the
 * other phone instead of uploaded. Other projects are uploaded without build
 * output and dependency folders. Provider keys and tokens never leave the
 * phone.
 */

import {
	copyFileSync,
	cpSync,
	existsSync,
	lstatSync,
	mkdirSync,
	readdirSync,
	readFileSync,
	rmSync,
	statSync,
	writeFileSync,
} from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { type Integrations, run } from "./integrations.js";
import type { CustomProviders } from "./providers.js";

const REPO = "andropi-sync";
/** GitHub rejects files over 100 MB. */
const MAX_FILE = 95 * 1024 * 1024;
const SKIP_DIRS = new Set([".git", "node_modules", ".venv", "venv", "__pycache__", ".gradle", "build", ".next", "target", ".dart_tool", "backups"]);
/** App configuration that travels: prompt templates, skills, agent instructions, pi settings. */
const CONFIG = ["prompts", "skills", "AGENTS.md", "settings.json"];

export interface SyncDeps {
	agentDir: string;
	workspace: string;
	stateDir: string;
	integrations: Integrations;
	providers: CustomProviders;
	/** The chat file open right now; it is never overwritten from the remote. */
	activeSession(): string | undefined;
	/** True while the agent or a background task is working. */
	busy(): boolean;
	/** Called after custom providers were added, so the model list can reload. */
	providersChanged(): Promise<void>;
	notify(status: SyncStatus): void;
}

export interface SyncStatus {
	enabled: boolean;
	running: boolean;
	repo: string | null;
	lastSync: number | null;
	lastError: string | null;
	/** Failed syncs in a row; the app notifies once this reaches a few. */
	failures: number;
	/** Files left out because they are too big for GitHub. */
	skipped: string[];
	/** Projects deleted on another phone but kept on this one; they are no longer uploaded. */
	localOnly: string[];
	/** What the last sync brought in from other phones. */
	imported: { chats: number; projects: number; config: number; removed: number };
}

interface State {
	enabled: boolean;
	lastSync: number | null;
	lastError: string | null;
	failures: number;
	skipped: string[];
	imported: SyncStatus["imported"];
	/** Item keys present after the last sync, to tell "deleted here" from "new elsewhere". */
	synced: string[];
	localOnly: string[];
}

const exists = (p: string) => existsSync(p);

/** A project folder name that stays inside the workspace. */
const safeName = (name: unknown): name is string =>
	typeof name === "string" && /^[^/\\]+$/.test(name) && !name.startsWith(".");
/** A remote another phone can clone; never something git would read as an option. */
const safeRemote = (url: unknown): url is string => typeof url === "string" && /^(https:\/\/|ssh:\/\/|git@)\S+$/.test(url);
const safeBranch = (b: unknown): b is string => typeof b === "string" && /^[\w.\/-]+$/.test(b) && !b.startsWith("-");
/** Credentials someone put into a remote URL must not land in the sync repository. */
const withoutCredentials = (url: string) => url.replace(/^(https?:\/\/)[^@/]+@/, "$1");

/** Files under [dir], relative to it. Symlinks are skipped: they may dangle, loop, or point outside. */
function walk(dir: string, skipDirs?: Set<string>, base = dir, out: string[] = []): string[] {
	if (!exists(dir)) return out;
	for (const name of readdirSync(dir)) {
		const p = join(dir, name);
		const st = lstatSync(p);
		if (st.isSymbolicLink()) continue;
		if (st.isDirectory()) {
			if (!skipDirs?.has(name)) walk(p, skipDirs, base, out);
		} else if (st.isFile()) {
			out.push(relative(base, p));
		}
	}
	return out;
}

/**
 * Makes [dst] a copy of [src], copying only files that changed and removing ones gone from [src]. Files over
 * GitHub's limit are left out and reported through [onTooBig]; [keep] names files in [dst] to leave as they are.
 * Returns the relative paths now in [dst].
 */
function mirrorTree(
	src: string,
	dst: string,
	opts: { skipDirs?: Set<string>; only?: (rel: string) => boolean; keep?: Set<string>; onTooBig: (rel: string) => void },
): string[] {
	const kept = new Set<string>();
	for (const rel of walk(src, opts.skipDirs)) {
		if (opts.only && !opts.only(rel)) continue;
		if (opts.keep?.has(rel) && exists(join(dst, rel))) {
			kept.add(rel);
			continue;
		}
		const from = lstatSync(join(src, rel));
		if (from.size > MAX_FILE) {
			opts.onTooBig(rel);
			continue;
		}
		const to = join(dst, rel);
		const old = exists(to) ? lstatSync(to) : null;
		if (!old || !old.isFile() || old.size !== from.size || from.mtimeMs > old.mtimeMs) {
			if (old && !old.isFile()) rmSync(to, { recursive: true, force: true });
			mkdirSync(dirname(to), { recursive: true });
			copyFileSync(join(src, rel), to);
		}
		kept.add(rel);
	}
	for (const rel of walk(dst)) {
		if (!kept.has(rel)) rmSync(join(dst, rel), { force: true });
	}
	return [...kept];
}

export class GitHubSync {
	private state: State;
	private readonly file: string;
	private readonly dir: string;
	private running = false;
	private again = false;
	private timer: NodeJS.Timeout | undefined;
	private due = 0;
	private repo: string | null = null;
	/** The open chat grew on another phone: leave the longer copy in the repository until it can be pulled. */
	private keepRemote = new Set<string>();

	constructor(private readonly deps: SyncDeps) {
		this.file = join(deps.stateDir, "sync.json");
		this.dir = join(deps.stateDir, "sync-repo");
		const empty: State = {
			enabled: false,
			lastSync: null,
			lastError: null,
			failures: 0,
			skipped: [],
			imported: { chats: 0, projects: 0, config: 0, removed: 0 },
			synced: [],
			localOnly: [],
		};
		try {
			this.state = { ...empty, ...JSON.parse(readFileSync(this.file, "utf8")) };
		} catch {
			this.state = empty;
		}
	}

	status(): SyncStatus {
		const { enabled, lastSync, lastError, failures, skipped, imported, localOnly } = this.state;
		return { enabled, running: this.running, repo: this.repo, lastSync, lastError, failures, skipped, localOnly, imported };
	}

	private save() {
		writeFileSync(this.file, JSON.stringify(this.state));
		this.deps.notify(this.status());
	}

	async setEnabled(on: boolean) {
		if (on && !this.deps.integrations.summary().github) throw new Error("Sign in to GitHub first");
		this.state.enabled = on;
		this.state.lastError = null;
		this.state.failures = 0;
		this.save();
		clearTimeout(this.timer);
		this.timer = undefined;
		if (on) this.schedule(0);
		return this.status();
	}

	/** Runs a sync after [delayMs]; a sooner request replaces a later one, a later one leaves a sooner one alone. */
	schedule(delayMs: number) {
		if (!this.state.enabled) return;
		const at = Date.now() + delayMs;
		if (this.timer && this.due <= at) return;
		clearTimeout(this.timer);
		this.due = at;
		this.timer = setTimeout(() => {
			this.timer = undefined;
			void this.syncNow().catch(() => {});
		}, delayMs);
	}

	async syncNow(): Promise<SyncStatus> {
		if (!this.state.enabled) throw new Error("GitHub sync is off");
		if (this.running) {
			this.again = true;
			return this.status();
		}
		// Chats are being written while the agent works; wait for a quiet moment.
		if (this.deps.busy()) {
			this.schedule(30_000);
			return this.status();
		}
		this.running = true;
		this.deps.notify(this.status());
		try {
			await this.sync();
			this.state.lastError = null;
			this.state.failures = 0;
		} catch (e) {
			this.state.lastError = String((e as Error)?.message ?? e).slice(0, 500);
			this.state.failures++;
		} finally {
			this.running = false;
			this.save();
		}
		if (this.again) {
			this.again = false;
			this.schedule(1000);
		}
		return this.status();
	}

	// -------------------------------------------------------------------------

	private git(args: string[]) {
		return run("git", args, { cwd: this.dir });
	}

	/** Finds or creates the private repository and returns its owner/name. */
	private async ensureRepo() {
		const gh = this.deps.integrations.summary().github;
		if (!gh) throw new Error("Sign in to GitHub first");
		const api = (p: string, init?: RequestInit) => this.deps.integrations.githubApi(p, init);
		let repo: any;
		try {
			repo = await api(`/repos/${gh.login}/${REPO}`);
		} catch (e: any) {
			if (e?.status !== 404) throw e;
			repo = await api("/user/repos", {
				method: "POST",
				body: JSON.stringify({
					name: REPO,
					private: true,
					auto_init: true,
					description: "AndroPI chats, projects and settings (synced by the app)",
				}),
			});
		}
		// Chats can hold anything that was pasted into them; never sync into a public repository.
		if (!repo.private) throw new Error(`${repo.full_name} is public. Make it private or rename it, then sync again.`);
		this.repo = repo.full_name as string;
		return { fullName: this.repo, branch: (repo.default_branch as string) || "main" };
	}

	/** A local clone at the remote's latest commit; local leftovers from a failed run are dropped. */
	private async checkout(fullName: string, branch: string) {
		const url = `https://github.com/${fullName}.git`;
		if (!exists(join(this.dir, ".git"))) {
			rmSync(this.dir, { recursive: true, force: true });
			mkdirSync(this.dir, { recursive: true });
			await this.git(["init", "-q"]);
			await this.git(["remote", "add", "origin", url]);
		} else {
			await this.git(["remote", "set-url", "origin", url]);
		}
		await this.git(["fetch", "-q", "origin"]);
		const hasRemote = await this.git(["rev-parse", "--verify", "-q", `origin/${branch}`]).then(
			() => true,
			() => false,
		);
		if (hasRemote) {
			await this.git(["checkout", "-q", "-B", branch, `origin/${branch}`]);
			await this.git(["reset", "-q", "--hard", `origin/${branch}`]);
			await this.git(["clean", "-qfdx"]);
		} else {
			await this.git(["checkout", "-q", "--orphan", branch]).catch(() => "");
		}
	}

	private async sync() {
		const { fullName, branch } = await this.ensureRepo();
		await this.checkout(fullName, branch);
		const synced = new Set(this.state.synced);
		const imported = await this.pull(synced);
		const { items, skipped } = await this.mirror();
		await this.git(["add", "-A"]);
		const changed = (await this.git(["status", "--porcelain"])).trim().length > 0;
		if (changed) {
			await this.git(["commit", "-q", "-m", `Sync ${new Date().toISOString()}`]);
			try {
				await this.git(["push", "-q", "origin", `HEAD:${branch}`]);
			} catch (e) {
				// Another phone pushed meanwhile: start over from its commit. Any other failure is reported as is.
				await this.git(["fetch", "-q", "origin"]).catch(() => "");
				const behind = await this.git(["rev-list", "--count", `HEAD..origin/${branch}`]).then(
					(n) => Number(n.trim()) > 0,
					() => false,
				);
				if (!behind) throw e;
				this.again = true;
				throw new Error("Another device synced at the same time; trying again");
			}
		}
		this.state.synced = items;
		this.state.skipped = skipped;
		this.state.imported = imported;
		this.state.lastSync = Date.now();
		if (imported.config) await this.deps.providersChanged();
	}

	/** Copies in what other phones added. */
	private async pull(synced: Set<string>) {
		const { agentDir, workspace } = this.deps;
		const imported = { chats: 0, projects: 0, config: 0, removed: 0 };
		const isNew = (key: string, local: string) => !exists(local) && !synced.has(key);
		const active = this.deps.activeSession();
		this.keepRemote.clear();

		// Chats deleted on another phone since the last sync. Skipped if the repository has no chats at
		// all (emptied or reset), so a wiped remote never empties this phone. Projects are never deleted.
		if (exists(join(this.dir, "sessions"))) {
			for (const key of synced) {
				if (!key.startsWith("sessions/") || exists(join(this.dir, key))) continue;
				const local = join(agentDir, key);
				if (active && resolve(local) === resolve(active)) continue;
				if (exists(local)) {
					rmSync(local);
					imported.removed++;
				}
			}
		}

		// Chats: new ones, and longer copies of ones this phone has (continued elsewhere).
		for (const rel of walk(join(this.dir, "sessions"))) {
			if (!rel.endsWith(".jsonl")) continue;
			const from = join(this.dir, "sessions", rel);
			const to = join(agentDir, "sessions", rel);
			const newer = exists(to) && statSync(from).size > statSync(to).size;
			if (active && resolve(to) === resolve(active)) {
				// Never rewritten while open; but don't let this phone's shorter copy replace the longer one either.
				if (newer) this.keepRemote.add(rel);
				continue;
			}
			if (isNew(`sessions/${rel}`, to) || newer) {
				mkdirSync(dirname(to), { recursive: true });
				cpSync(from, to);
				imported.chats++;
			}
		}

		// Projects deleted on another phone: kept here (never deleted automatically) but no longer uploaded,
		// so they don't come back on the phone that deleted them.
		const manifest = join(this.dir, "projects.json");
		const gitProjects: { name: string; remote: string; branch: string | null }[] = (
			exists(manifest) ? JSON.parse(readFileSync(manifest, "utf8")) : []
		).filter((p: any) => safeName(p?.name) && safeRemote(p?.remote));
		if (exists(manifest)) {
			const remote = new Set([
				...(exists(join(this.dir, "projects")) ? readdirSync(join(this.dir, "projects")) : []),
				...gitProjects.map((p) => p.name),
			]);
			for (const key of synced) {
				const name = key.startsWith("projects/") || key.startsWith("git/") ? key.slice(key.indexOf("/") + 1) : null;
				if (name && !remote.has(name) && exists(join(workspace, name)) && !this.state.localOnly.includes(name)) {
					this.state.localOnly.push(name);
				}
			}
		}
		this.state.localOnly = this.state.localOnly.filter((name) => exists(join(workspace, name)));

		// Projects uploaded by another phone.
		for (const name of exists(join(this.dir, "projects")) ? readdirSync(join(this.dir, "projects")) : []) {
			const to = join(workspace, name);
			if (!safeName(name) || !isNew(`projects/${name}`, to)) continue;
			cpSync(join(this.dir, "projects", name), to, {
				recursive: true,
				filter: (src) => !lstatSync(src).isSymbolicLink(),
			});
			imported.projects++;
		}

		// Git projects: clone them.
		for (const p of gitProjects) {
			const to = join(workspace, p.name);
			if (!isNew(`git/${p.name}`, to)) continue;
			const args = ["clone", "-q", ...(safeBranch(p.branch) ? ["-b", p.branch] : []), "--", p.remote, to];
			await run("git", args, { cwd: workspace }).then(
				() => imported.projects++,
				() => {},
			);
		}

		// Configuration missing on this phone (a fresh install).
		for (const rel of walk(join(this.dir, "config"))) {
			const to = join(agentDir, rel);
			if (rel === "custom-providers.json" || !isNew(`config/${rel}`, to)) continue;
			mkdirSync(dirname(to), { recursive: true });
			cpSync(join(this.dir, "config", rel), to);
			imported.config++;
		}
		const providersFile = join(this.dir, "config", "custom-providers.json");
		if (exists(providersFile)) {
			const have = this.deps.providers.ids();
			for (const p of JSON.parse(readFileSync(providersFile, "utf8"))) {
				if (have.has(p.id) || synced.has(`provider/${p.id}`)) continue;
				// Added without its key; the user enters it again on this phone.
				this.deps.providers.save({ ...p, apiKey: "" }, new Set());
				imported.config++;
			}
		}
		return imported;
	}

	/** Makes the clone's working tree a copy of this phone; returns the item keys and skipped files. */
	private async mirror() {
		const { agentDir, workspace } = this.deps;
		const items: string[] = [];
		const skipped: string[] = [];
		const tooBig = (label: string) => (rel: string) => skipped.push(`${label}/${rel}`);

		for (const rel of mirrorTree(join(agentDir, "sessions"), join(this.dir, "sessions"), {
			only: (rel) => rel.endsWith(".jsonl"),
			keep: this.keepRemote,
			onTooBig: tooBig("chats"),
		})) {
			items.push(`sessions/${rel}`);
		}

		const gitProjects: { name: string; remote: string; branch: string | null }[] = [];
		const uploaded = new Set<string>();
		for (const name of exists(workspace) ? readdirSync(workspace) : []) {
			const dir = join(workspace, name);
			if (!safeName(name) || name === "backups" || !lstatSync(dir).isDirectory()) continue;
			if (this.state.localOnly.includes(name)) continue;
			const origin = exists(join(dir, ".git"))
				? (await run("git", ["remote", "get-url", "origin"], { cwd: dir }).catch(() => "")).trim()
				: "";
			const remote = withoutCredentials(origin);
			if (safeRemote(remote)) {
				const branch = (await run("git", ["branch", "--show-current"], { cwd: dir }).catch(() => "")).trim() || null;
				gitProjects.push({ name, remote, branch });
				items.push(`git/${name}`);
			} else {
				// No remote another phone could clone (none, or a local path): upload the files.
				mirrorTree(dir, join(this.dir, "projects", name), { skipDirs: SKIP_DIRS, onTooBig: tooBig(name) });
				uploaded.add(name);
				items.push(`projects/${name}`);
			}
		}
		for (const name of exists(join(this.dir, "projects")) ? readdirSync(join(this.dir, "projects")) : []) {
			if (!uploaded.has(name)) rmSync(join(this.dir, "projects", name), { recursive: true, force: true });
		}
		writeFileSync(join(this.dir, "projects.json"), `${JSON.stringify(gitProjects, null, 1)}\n`);

		const config = new Set<string>(["custom-providers.json"]);
		for (const entry of CONFIG) {
			const from = join(agentDir, entry);
			if (!exists(from) || lstatSync(from).isSymbolicLink()) continue;
			const to = join(this.dir, "config", entry);
			if (lstatSync(from).isDirectory()) {
				for (const rel of mirrorTree(from, to, { onTooBig: tooBig(entry) })) {
					config.add(join(entry, rel));
					items.push(`config/${entry}/${rel}`);
				}
			} else {
				mkdirSync(dirname(to), { recursive: true });
				copyFileSync(from, to);
				config.add(entry);
				items.push(`config/${entry}`);
			}
		}
		for (const rel of walk(join(this.dir, "config"))) {
			if (!config.has(rel)) rmSync(join(this.dir, "config", rel), { force: true });
		}
		// Endpoints and model lists only; keys stay on the phone.
		const providers = this.deps.providers.list().map(({ hasKey: _hasKey, ...p }) => p);
		mkdirSync(join(this.dir, "config"), { recursive: true });
		writeFileSync(join(this.dir, "config", "custom-providers.json"), `${JSON.stringify(providers, null, 1)}\n`);
		for (const p of providers) items.push(`provider/${p.id}`);

		writeFileSync(
			join(this.dir, "README.md"),
			"# AndroPI sync\n\nChats, projects and settings synced by the AndroPI app. Keep this repository private.\n" +
				"Provider keys and tokens are not stored here.\n",
		);
		return { items, skipped };
	}
}
