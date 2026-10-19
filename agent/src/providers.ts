/**
 * Custom model providers: any OpenAI-, Anthropic- or Google-compatible endpoint
 * the user adds with a base URL and an API key (proxies, Ollama, LM Studio,
 * vLLM, ...).
 *
 * The app keeps them in its own encrypted store and writes pi's models.json
 * from it. models.json only references each key as `$ANDROPI_PROVIDER_KEY_<ID>`,
 * which pi resolves from the environment, so keys never sit there in plain
 * text. Providers in models.json that the app did not add are left untouched.
 */

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { readSecureJson, writeSecureJson } from "./secure.js";

export const APIS = ["openai-completions", "openai-responses", "anthropic-messages", "google-generative-ai"] as const;
export type ProviderApi = (typeof APIS)[number];

export type CustomModel = { id: string; name?: string; contextWindow?: number; reasoning?: boolean; input?: string[] };

export type CustomProvider = {
	id: string;
	name: string;
	api: ProviderApi;
	baseUrl: string;
	apiKey: string;
	models: CustomModel[];
};

/** Local servers ignore the key, but pi only lists models whose provider has one. */
const NO_KEY = "none";

function envName(id: string) {
	return `ANDROPI_PROVIDER_KEY_${id.toUpperCase().replace(/[^A-Z0-9]/g, "_")}`;
}

function cleanUrl(url: string) {
	return url.trim().replace(/\/+$/, "");
}

export class CustomProviders {
	private providers: CustomProvider[];

	constructor(
		private readonly storeFile: string,
		private readonly modelsFile: string,
	) {
		this.providers = readSecureJson<CustomProvider[]>(storeFile, []);
	}

	ids() {
		return new Set(this.providers.map((p) => p.id));
	}

	/** What the app shows; keys are never sent back. */
	list() {
		return this.providers.map(({ apiKey, ...rest }) => ({ ...rest, hasKey: !!apiKey }));
	}

	/** Exposes the keys to pi; call before the model runtime (re)loads models.json. */
	applyEnv() {
		for (const p of this.providers) process.env[envName(p.id)] = p.apiKey || NO_KEY;
	}

	/**
	 * Adds or updates a provider. An empty apiKey keeps the saved one.
	 * `builtin` holds provider ids pi already knows, which a new provider may not reuse.
	 */
	save(input: Partial<CustomProvider> & { previousId?: string }, builtin: Set<string>) {
		const id = String(input.id ?? "").trim();
		if (!/^[a-z0-9][a-z0-9_-]*$/.test(id)) throw new Error("Provider ID: lowercase letters, digits, - and _ only");
		const api = input.api as ProviderApi;
		if (!APIS.includes(api)) throw new Error(`Unknown API type ${input.api}`);
		const baseUrl = cleanUrl(String(input.baseUrl ?? ""));
		if (!/^https?:\/\/[^/]+/.test(baseUrl)) throw new Error("Enter a full base URL (https://…)");
		const models = (input.models ?? [])
			.map((m) => ({ ...m, id: String(m.id ?? "").trim() }))
			.filter((m, i, all) => m.id && all.findIndex((x) => x.id === m.id) === i);
		if (!models.length) throw new Error("Add at least one model (or fetch them from the endpoint)");

		const previousId = input.previousId ?? id;
		const previous = this.providers.find((p) => p.id === previousId);
		if (id !== previousId && this.providers.some((p) => p.id === id)) throw new Error(`${id} already exists`);
		if (!this.ids().has(id) && builtin.has(id)) throw new Error(`${id} is a built-in provider; pick another ID`);

		const provider: CustomProvider = {
			id,
			name: String(input.name ?? "").trim() || id,
			api,
			baseUrl,
			apiKey: String(input.apiKey ?? "").trim() || previous?.apiKey || "",
			models,
		};
		this.providers = [...this.providers.filter((p) => p.id !== previousId), provider];
		this.persist(previousId === id ? [] : [previousId]);
		return provider;
	}

	remove(id: string) {
		this.providers = this.providers.filter((p) => p.id !== id);
		this.persist([id]);
	}

	/** The stored key for a provider, so "Fetch models" works without retyping it. */
	key(id: string) {
		return this.providers.find((p) => p.id === id)?.apiKey ?? "";
	}

	private persist(removed: string[]) {
		writeSecureJson(this.storeFile, this.providers);
		for (const id of removed) delete process.env[envName(id)];
		this.applyEnv();
		this.writeModelsJson(removed);
	}

	private writeModelsJson(removed: string[]) {
		let config: { providers?: Record<string, unknown>; [key: string]: unknown } = {};
		if (existsSync(this.modelsFile)) {
			// Never overwrite a models.json the user wrote by hand if it cannot be read.
			try {
				config = JSON.parse(readFileSync(this.modelsFile, "utf8"));
			} catch (e) {
				throw new Error(`models.json is not valid JSON, fix or delete it first: ${(e as Error).message}`);
			}
		}
		const providers = { ...(config.providers ?? {}) };
		for (const id of removed) delete providers[id];
		for (const p of this.providers) {
			providers[p.id] = {
				name: p.name,
				baseUrl: p.baseUrl,
				api: p.api,
				apiKey: `$${envName(p.id)}`,
				models: p.models.map((m) => ({
					id: m.id,
					...(m.name ? { name: m.name } : {}),
					...(m.contextWindow ? { contextWindow: m.contextWindow } : {}),
					...(m.reasoning ? { reasoning: true } : {}),
					...(m.input?.length ? { input: m.input } : {}),
				})),
			};
		}
		writeFileSync(this.modelsFile, JSON.stringify({ ...config, providers }, null, 2));
	}
}

/** Asks the endpoint which models it serves (`GET …/models`). */
export async function fetchModels(api: ProviderApi, baseUrl: string, apiKey: string): Promise<CustomModel[]> {
	const base = cleanUrl(baseUrl);
	if (!/^https?:\/\/[^/]+/.test(base)) throw new Error("Enter a full base URL (https://…)");
	const headers: Record<string, string> = { accept: "application/json" };
	let url = `${base}/models`;
	if (api === "anthropic-messages") {
		// pi's Anthropic base URL has no /v1; accept either form here.
		if (!/\/v1$/.test(base)) url = `${base}/v1/models?limit=1000`;
		if (apiKey) headers["x-api-key"] = apiKey;
		headers["anthropic-version"] = "2023-06-01";
	} else if (api === "google-generative-ai") {
		url = `${base}/models?pageSize=1000`;
		if (apiKey) headers["x-goog-api-key"] = apiKey;
	} else if (apiKey) {
		headers.authorization = `Bearer ${apiKey}`;
	}

	const res = await fetch(url, { headers, signal: AbortSignal.timeout(20_000) });
	const body = await res.text();
	if (!res.ok) throw new Error(`${res.status} ${res.statusText}: ${body.slice(0, 300)}`);
	let json: any;
	try {
		json = JSON.parse(body);
	} catch {
		throw new Error(`The endpoint did not return JSON: ${body.slice(0, 200)}`);
	}

	const items: any[] = Array.isArray(json) ? json : (json.data ?? json.models ?? []);
	const models: CustomModel[] = [];
	for (const m of items) {
		if (api === "google-generative-ai") {
			if (Array.isArray(m.supportedGenerationMethods) && !m.supportedGenerationMethods.includes("generateContent"))
				continue;
			const id = String(m.name ?? "").replace(/^models\//, "");
			if (id) models.push({ id, name: m.displayName || undefined, contextWindow: m.inputTokenLimit || undefined });
			continue;
		}
		const id = typeof m === "string" ? m : String(m.id ?? m.name ?? "");
		if (!id) continue;
		const contextWindow = Number(m.context_length ?? m.context_window ?? m.max_context_length ?? 0) || undefined;
		const input = m.architecture?.input_modalities?.includes?.("image") ? ["text", "image"] : undefined;
		models.push({ id, name: m.display_name || (m.name !== id ? m.name : undefined) || undefined, contextWindow, input });
	}
	if (!models.length) throw new Error("The endpoint returned no models");
	return models.sort((a, b) => a.id.localeCompare(b.id));
}
