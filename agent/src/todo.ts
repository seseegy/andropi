/**
 * todo_write: the agent's plan for a multi-step task, as a checklist the app shows (a card in the chat, a progress
 * bar above the input, the step in the ongoing notification).
 *
 * The agent always sends the whole list, so the latest call is the current plan: the app reads it straight from the
 * tool call's arguments, and it is saved with the chat like any other message (branches and sync included).
 */

import { Type } from "typebox";

export type TodoStatus = "pending" | "in_progress" | "completed";

export interface Todo {
	content: string;
	status: TodoStatus;
	/** The step as it is happening ("Running the tests"), shown while it is in progress. */
	activeForm?: string;
}

const STATUSES = new Set<TodoStatus>(["pending", "in_progress", "completed"]);

/** "None", "null" and the like, which some models send for an empty field. */
const EMPTY = /^(none|null|undefined|n\/a)?$/i;

/** The list from a model's arguments: an array, or the same array sent as a JSON string (common outside Anthropic). */
function listOf(raw: unknown): unknown[] {
	if (typeof raw === "string") {
		try {
			return listOf(JSON.parse(raw));
		} catch {
			return [];
		}
	}
	return Array.isArray(raw) ? raw : [];
}

/** Cleans up what a model sends: drops empty items, maps loose statuses, and keeps one step in progress. */
export function normalizeTodos(raw: unknown): Todo[] {
	const list = listOf(raw);
	const todos: Todo[] = [];
	for (const item of list) {
		if (!item || typeof item !== "object") continue;
		const o = item as Record<string, unknown>;
		const content = String(o.content ?? o.text ?? o.title ?? "").trim();
		if (EMPTY.test(content)) continue;
		let status = String(o.status ?? "pending")
			.toLowerCase()
			.replace(/[\s-]+/g, "_") as TodoStatus;
		if (status === ("done" as TodoStatus) || status === ("complete" as TodoStatus)) status = "completed";
		if (status === ("active" as TodoStatus) || status === ("doing" as TodoStatus)) status = "in_progress";
		if (!STATUSES.has(status)) status = "pending";
		const activeForm =
			typeof o.activeForm === "string" && !EMPTY.test(o.activeForm.trim()) ? o.activeForm.trim() : undefined;
		todos.push({ content, status, ...(activeForm && { activeForm }) });
	}
	// One step at a time: later "in progress" items wait.
	let active = false;
	for (const t of todos) {
		if (t.status !== "in_progress") continue;
		if (active) t.status = "pending";
		active = true;
	}
	return todos.slice(0, 50);
}

/** The plan as the model reads it back. */
export function describeTodos(todos: Todo[]) {
	if (!todos.length) return "The todo list is now empty.";
	const done = todos.filter((t) => t.status === "completed").length;
	const mark = { pending: "[ ]", in_progress: "[~]", completed: "[x]" } as const;
	return [
		`Todo list updated (${done}/${todos.length} done):`,
		...todos.map((t, i) => `${mark[t.status]} ${i + 1}. ${t.content}`),
		done === todos.length
			? "All steps are done."
			: "Keep it current: mark each step completed as soon as it is done, and the next one in_progress.",
	].join("\n");
}

export function todoTool() {
	return {
		name: "todo_write",
		label: "Plan",
		description:
			"Write the plan for the current task as a todo list the user sees in the app. Send the whole list every time (it replaces the previous one). " +
			"Use it for tasks with three or more steps, or when the user gives several things to do; skip it for quick questions and one-step changes. " +
			"Exactly one item should be in_progress while you work; mark an item completed as soon as it is done, not in batches. " +
			"Add items you discover along the way, and remove ones that no longer apply.",
		promptSnippet: "todo_write: plan multi-step tasks as a checklist the user can follow",
		promptGuidelines: [
			"For a task with three or more steps, call todo_write first with the plan, then keep it updated as you go: one step in_progress at a time, each marked completed right after it is done.",
			"Do not use todo_write for simple questions or single small edits.",
		],
		parameters: Type.Object({
			todos: Type.Array(
				Type.Object({
					content: Type.String({ description: "The step, in the imperative: \"Run the tests\"" }),
					status: Type.String({ description: "pending, in_progress or completed" }),
					activeForm: Type.Optional(
						Type.String({ description: "The step while it happens: \"Running the tests\"" }),
					),
				}),
				{ description: "The full list, in order" },
			),
		}),
		// Before validation: accept the list as a JSON string, "text"/"title" for content and a missing status,
		// instead of failing the call over its shape.
		prepareArguments(args: unknown) {
			const todos = normalizeTodos((args as { todos?: unknown } | null)?.todos);
			return { todos: todos.map((t) => ({ ...t })) };
		},
		async execute(_id: string, params: { todos: unknown }) {
			const todos = normalizeTodos(params.todos);
			return { content: [{ type: "text" as const, text: describeTodos(todos) }], details: { todos } };
		},
	};
}
