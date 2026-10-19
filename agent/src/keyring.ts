/**
 * API keys for the search services: several per service, used in turn, and set aside for a while when one is
 * rate-limited, out of credits or rejected, so the next one takes over.
 */

/** A request a key couldn't serve, with the HTTP status that says why. */
export class KeyError extends Error {
	constructor(
		message: string,
		readonly status: number,
	) {
		super(message);
	}
}

/**
 * Keys from pasted text: one per line, though spaces, commas and semicolons separate them too. Quotes around a
 * key, blank lines, "#" comments and repeats are dropped.
 */
export function parseKeys(text: string | undefined | null): string[] {
	const keys: string[] = [];
	for (const line of (text ?? "").split(/\r?\n/)) {
		if (line.trim().startsWith("#")) continue;
		for (const raw of line.split(/[\s,;]+/)) {
			const key = raw.replace(/^["'`]+|["'`]+$/g, "");
			if (key && !keys.includes(key)) keys.push(key);
		}
	}
	return keys;
}

/** "…a1b2": enough to tell keys apart in the app, never the key itself. */
export function maskKey(key: string) {
	return `…${key.slice(-4)}`;
}

const restingUntil = new Map<string, number>();
const nextStart = new Map<string, number>();

/** Statuses that are about the key (or its account), not the request. */
const KEY_PROBLEM = new Set([401, 402, 403, 429, 432]);

/**
 * Runs [run] with the service's keys in turn, starting after the last one used so the load spreads. A key that
 * fails with a key problem rests (a minute when rate-limited, ten minutes otherwise) and the next one is tried;
 * any other failure is thrown as is. [keyProblem] narrows which statuses count.
 */
export async function withKeys<T>(
	service: string,
	keys: string[],
	run: (key: string) => Promise<T>,
	keyProblem: (status: number) => boolean = (s) => KEY_PROBLEM.has(s),
): Promise<T> {
	if (!keys.length) throw new Error(`No ${service} key`);
	const now = Date.now();
	const start = (nextStart.get(service) ?? 0) % keys.length;
	const order = [...keys.slice(start), ...keys.slice(0, start)];
	// Resting keys go last rather than being skipped: better a likely failure than no attempt at all.
	order.sort((a, b) => Number((restingUntil.get(a) ?? 0) > now) - Number((restingUntil.get(b) ?? 0) > now));
	const failures: string[] = [];
	for (const key of order) {
		try {
			const result = await run(key);
			restingUntil.delete(key);
			nextStart.set(service, keys.indexOf(key) + 1);
			return result;
		} catch (e) {
			if (!(e instanceof KeyError) || !keyProblem(e.status)) throw e;
			restingUntil.set(key, Date.now() + (e.status === 429 ? 60_000 : 600_000));
			failures.push(`${maskKey(key)}: ${e.message}`);
		}
	}
	throw new Error(`All ${service} keys failed (${failures.join("; ")})`);
}
