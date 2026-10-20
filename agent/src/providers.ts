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

export type CustomModel = {
	id: string;
	name?: string;
	contextWindow?: number;
	/** Longest reply the model can write, in tokens. */
	maxTokens?: number;
	/** Thinks before answering; the app then offers a thinking effort. */
	reasoning?: boolean;
	/** False when thinking can't be turned off (only effort levels, no "off"); true when the endpoint says it can. */
	canDisableThinking?: boolean;
	/** False when the endpoint says effort levels make no difference: thinking is just on (or off). */
	effort?: boolean;
	input?: string[];
};

/** A model as saved: only known fields, with sane types. */
function cleanModel(m: any): CustomModel {
	const num = (v: unknown) => (typeof v === "number" && v > 0 ? Math.round(v) : undefined);
	return {
		id: String(m.id ?? "").trim(),
		...(typeof m.name === "string" && m.name.trim() && { name: m.name.trim() }),
		...(num(m.contextWindow) && { contextWindow: num(m.contextWindow) }),
		...(num(m.maxTokens) && { maxTokens: num(m.maxTokens) }),
		...(m.reasoning === true && { reasoning: true }),
		...(m.reasoning === true && typeof m.canDisableThinking === "boolean" && { canDisableThinking: m.canDisableThinking }),
		...(m.reasoning === true && m.effort === false && { effort: false }),
		...(Array.isArray(m.input) && m.input.includes("image") && { input: ["text", "image"] }),
	};
}

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
			.map(cleanModel)
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
					...(m.maxTokens ? { maxTokens: requestedOutput(m) } : {}),
					...(m.reasoning ? { reasoning: true, thinkingLevelMap: thinkingLevels(m, p.api) } : {}),
					...(m.input?.length ? { input: m.input } : {}),
				})),
			};
		}
		writeFileSync(this.modelsFile, JSON.stringify({ ...config, providers }, null, 2));
	}
}

/**
 * What a `/models` entry says about a model, across the shapes endpoints use: a `capabilities` object
 * (OpenAI-style proxies), OpenRouter's `architecture` / `supported_parameters` / `top_provider`, and plain
 * `context_window` / `max_output_tokens` fields. Unknown stays unknown.
 */
export function capabilitiesOf(m: any): Omit<CustomModel, "id" | "name"> {
	// A capabilities object, or a list of names (["vision", "thinking"]).
	const list: string[] = Array.isArray(m.capabilities) ? m.capabilities.map((c: unknown) => String(c).toLowerCase()) : [];
	const caps = m.capabilities && typeof m.capabilities === "object" && !Array.isArray(m.capabilities) ? m.capabilities : {};
	const limits = caps.limits ?? {};
	const supports = caps.supports ?? {};
	// Numbers, or numeric strings; never booleans (Number(true) is 1).
	const num = (v: unknown) => {
		const n = typeof v === "number" ? v : typeof v === "string" && /^\d+$/.test(v.trim()) ? Number(v) : NaN;
		return Number.isFinite(n) && n > 0 ? Math.round(n) : undefined;
	};
	const first = (...values: unknown[]) => values.map(num).find((v) => v !== undefined);
	const flag = (...values: unknown[]) => values.find((v) => typeof v === "boolean") as boolean | undefined;
	const params: string[] = Array.isArray(m.supported_parameters) ? m.supported_parameters : [];
	const modalities: string[] = m.architecture?.input_modalities ?? m.input_modalities ?? m.modalities?.input ?? [];

	// An explicit yes or no wins over hints such as supported parameters.
	const reasoning =
		flag(caps.reasoning, caps.thinking, supports.reasoning, supports.thinking, m.reasoning) ??
		(list.includes("reasoning") ||
			list.includes("thinking") ||
			params.includes("reasoning") ||
			params.includes("include_reasoning") ||
			params.includes("reasoning_effort"));
	const vision =
		flag(caps.vision, supports.vision, m.vision) ??
		(list.includes("vision") || list.includes("image") || m.type === "vlm" || modalities.includes?.("image"));

	// The prompt limit, when smaller, is what actually fits (a proxy may refuse prompts past it).
	const context = first(
		caps.contextWindow,
		caps.context_window,
		limits.max_context_window_tokens,
		m.context_window,
		m.context_length,
		m.max_context_window_tokens,
		m.max_context_length,
		m.top_provider?.context_length,
	);
	const prompt = first(m.max_input_tokens, m.max_prompt_tokens, limits.max_prompt_tokens, caps.maxInput);
	const contextWindow = context && prompt ? Math.min(context, prompt) : (context ?? prompt);

	const canDisable = flag(caps.thinkingCanDisable, caps.reasoningCanDisable);
	return {
		contextWindow,
		maxTokens: first(
			caps.maxOutput,
			caps.max_output_tokens,
			limits.max_output_tokens,
			m.max_output_tokens,
			m.max_completion_tokens,
			m.top_provider?.max_completion_tokens,
		),
		...(reasoning && { reasoning: true }),
		...(reasoning && canDisable !== undefined && { canDisableThinking: canDisable }),
		...(reasoning && flag(caps.thinkingEffortSupported, caps.reasoningEffortSupported) === false && { effort: false }),
		...(vision && { input: ["text", "image"] }),
	};
}

/**
 * The reply size pi asks for on every request (max_tokens). The model's full limit (up to 393k on some) would make
 * every request reserve that much: slow on some servers, and refused by credit checks on others. 32k leaves room
 * for long answers and thinking; the full limit is still shown in the app.
 */
function requestedOutput(m: CustomModel) {
	const limits = [m.maxTokens!, 32_768];
	if (m.contextWindow) limits.push(Math.floor(m.contextWindow / 4));
	return Math.max(1024, Math.min(...limits));
}

/**
 * Which of pi's thinking levels a custom reasoning model offers. "minimal" is an OpenAI-only effort, so it is off
 * the list; models that always think lose "off"; models whose effort makes no difference keep a single level (plus
 * off), which the app shows as on/off or not at all. When the endpoint says thinking can be turned off, "off" is
 * sent explicitly as reasoning_effort "none" on OpenAI-style APIs, rather than leaving the model at its default.
 */
function thinkingLevels(m: CustomModel, api: ProviderApi) {
	const map: Record<string, string | null> = { minimal: null };
	if (m.canDisableThinking === false) map.off = null;
	else if (m.canDisableThinking === true && api.startsWith("openai")) map.off = "none";
	if (m.effort === false) {
		map.low = null;
		map.high = null;
	}
	return map;
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
			if (!id) continue;
			models.push(
				cleanModel({
					id,
					name: m.displayName,
					contextWindow: m.inputTokenLimit,
					maxTokens: m.outputTokenLimit,
					reasoning: m.thinking === true,
					// Gemini chat models all take images.
					...(/^gemini/.test(id) && { input: ["text", "image"] }),
				}),
			);
			continue;
		}
		const id = typeof m === "string" ? m : String(m.id ?? m.name ?? "");
		if (!id) continue;
		if (typeof m === "string") {
			models.push({ id });
			continue;
		}
		models.push(cleanModel({ id, name: m.display_name || (m.name !== id ? m.name : undefined), ...capabilitiesOf(m) }));
	}
	if (!models.length) throw new Error("The endpoint returned no models");
	return models.sort((a, b) => a.id.localeCompare(b.id));
}
