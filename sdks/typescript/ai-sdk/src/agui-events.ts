/**
 * AG-UI wire shapes — single source of truth for everything that crosses the
 * ZAQ <-> client seam over HTTP+SSE.
 *
 * Mirrors `@ag-ui/core` `core/src/events.ts` + `core/src/types.ts` @ 0.0.57.
 * We intentionally model only the EVENT SUBSET ZAQ emits, plus the
 * `RunAgentInput` request body the client POSTs to the ZAQ AG-UI endpoint.
 *
 * Zod schemas are colocated with the TS types so consumers can validate-then-
 * narrow each SSE frame instead of trusting the socket. Keep this file
 * framework-free: no `ai`, no Next.js imports.
 */

import { z } from "zod";

// ---------------------------------------------------------------------------
// EventType — the discriminant on every AG-UI frame.
// We list the subset ZAQ's bridge actually broadcasts (RUN_*, TEXT_MESSAGE_*, TOOL_CALL_*,
// STATE_SNAPSHOT, STEP_*, CUSTOM). Other members are accepted-but-ignored so
// an upstream addition never hard-fails the stream.
// ---------------------------------------------------------------------------

export const AGUIEventType = {
	RUN_STARTED: "RUN_STARTED",
	RUN_FINISHED: "RUN_FINISHED",
	RUN_ERROR: "RUN_ERROR",
	STEP_STARTED: "STEP_STARTED",
	STEP_FINISHED: "STEP_FINISHED",
	TEXT_MESSAGE_START: "TEXT_MESSAGE_START",
	TEXT_MESSAGE_CONTENT: "TEXT_MESSAGE_CONTENT",
	TEXT_MESSAGE_END: "TEXT_MESSAGE_END",
	TOOL_CALL_START: "TOOL_CALL_START",
	TOOL_CALL_ARGS: "TOOL_CALL_ARGS",
	TOOL_CALL_END: "TOOL_CALL_END",
	TOOL_CALL_RESULT: "TOOL_CALL_RESULT",
	STATE_SNAPSHOT: "STATE_SNAPSHOT",
	CUSTOM: "CUSTOM",
} as const;

export type AGUIEventType = (typeof AGUIEventType)[keyof typeof AGUIEventType];

// ---------------------------------------------------------------------------
// Shared message-role vocabulary (ag-ui core/src/types.ts).
// ---------------------------------------------------------------------------

export const aguiTextMessageRoleSchema = z.enum([
	"developer",
	"system",
	"assistant",
	"user",
]);
export type AGUITextMessageRole = z.infer<typeof aguiTextMessageRoleSchema>;

export const aguiMessageRoleSchema = z.enum([
	"developer",
	"system",
	"assistant",
	"user",
	"tool",
]);
export type AGUIMessageRole = z.infer<typeof aguiMessageRoleSchema>;

/**
 * ToolCall as it appears inside an AssistantMessage (ag-ui core/src/types.ts).
 * `function.arguments` is a JSON-encoded string (NOT a parsed object) — matches
 * the OpenAI tool-call wire shape.
 */
export const aguiToolCallSchema = z.object({
	id: z.string(),
	type: z.literal("function"),
	function: z.object({
		name: z.string(),
		arguments: z.string(),
	}),
});
export type AGUIToolCall = z.infer<typeof aguiToolCallSchema>;

/**
 * Conversation message in `RunAgentInput.messages`. Discriminated on `role`.
 * Kept loose (`content: string`) on purpose — ZAQ only needs role + text +
 * tool linkage; rich multi-part content is flattened by `message-mapping.ts`
 * before it reaches the wire.
 */
export const aguiMessageSchema = z.object({
	id: z.string(),
	role: aguiMessageRoleSchema,
	content: z.string().optional(),
	name: z.string().optional(),
	// assistant-only
	toolCalls: z.array(aguiToolCallSchema).optional(),
	// tool-only — links a ToolMessage back to the assistant tool call
	toolCallId: z.string().optional(),
});
export type AGUIMessage = z.infer<typeof aguiMessageSchema>;

// ---------------------------------------------------------------------------
// BaseEvent — fields common to every frame (ag-ui core/src/events.ts).
// `.passthrough()` keeps unknown fields rather than stripping them, so a newer
// ZAQ build that adds a field never trips Zod.
// ---------------------------------------------------------------------------

const baseEventShape = {
	type: z.string(),
	timestamp: z.number().optional(),
	rawEvent: z.unknown().optional(),
};

// --- Lifecycle -------------------------------------------------------------

export const runStartedSchema = z
	.object({
		...baseEventShape,
		type: z.literal(AGUIEventType.RUN_STARTED),
		threadId: z.string(),
		runId: z.string(),
		parentRunId: z.string().optional(),
	})
	.passthrough();
export type RunStartedEvent = z.infer<typeof runStartedSchema>;

/**
 * RUN_FINISHED carries an optional outcome. `interrupt` is the HITL path:
 * ZAQ maps a workflow "waiting" state to `outcome.type === 'interrupt'` so the
 * adapter can surface an approval prompt.
 */
export const aguiInterruptSchema = z.object({
	id: z.string(),
	reason: z.string(),
	message: z.string().optional(),
	toolCallId: z.string().optional(),
	responseSchema: z.record(z.string(), z.unknown()).optional(),
	expiresAt: z.string().optional(),
	metadata: z.record(z.string(), z.unknown()).optional(),
});
export type AGUIInterrupt = z.infer<typeof aguiInterruptSchema>;

export const runFinishedSchema = z
	.object({
		...baseEventShape,
		type: z.literal(AGUIEventType.RUN_FINISHED),
		threadId: z.string(),
		runId: z.string(),
		result: z.unknown().optional(),
		outcome: z
			.union([
				z.object({ type: z.literal("success") }),
				z.object({
					type: z.literal("interrupt"),
					interrupts: z.array(aguiInterruptSchema).min(1),
				}),
			])
			.optional(),
	})
	.passthrough();
export type RunFinishedEvent = z.infer<typeof runFinishedSchema>;

export const runErrorSchema = z
	.object({
		...baseEventShape,
		type: z.literal(AGUIEventType.RUN_ERROR),
		message: z.string(),
		code: z.string().optional(),
	})
	.passthrough();
export type RunErrorEvent = z.infer<typeof runErrorSchema>;

export const stepStartedSchema = z
	.object({
		...baseEventShape,
		type: z.literal(AGUIEventType.STEP_STARTED),
		stepName: z.string(),
	})
	.passthrough();
export type StepStartedEvent = z.infer<typeof stepStartedSchema>;

export const stepFinishedSchema = z
	.object({
		...baseEventShape,
		type: z.literal(AGUIEventType.STEP_FINISHED),
		stepName: z.string(),
	})
	.passthrough();
export type StepFinishedEvent = z.infer<typeof stepFinishedSchema>;

// --- Text streaming --------------------------------------------------------

export const textMessageStartSchema = z
	.object({
		...baseEventShape,
		type: z.literal(AGUIEventType.TEXT_MESSAGE_START),
		messageId: z.string(),
		role: aguiTextMessageRoleSchema.default("assistant"),
	})
	.passthrough();
export type TextMessageStartEvent = z.infer<typeof textMessageStartSchema>;

/**
 * ZAQ token-streams: each `TEXT_MESSAGE_CONTENT` carries one incremental
 * `delta`, which the adapter forwards 1:1 as a `text-delta`.
 */
export const textMessageContentSchema = z
	.object({
		...baseEventShape,
		type: z.literal(AGUIEventType.TEXT_MESSAGE_CONTENT),
		messageId: z.string(),
		delta: z.string(),
	})
	.passthrough();
export type TextMessageContentEvent = z.infer<typeof textMessageContentSchema>;

export const textMessageEndSchema = z
	.object({
		...baseEventShape,
		type: z.literal(AGUIEventType.TEXT_MESSAGE_END),
		messageId: z.string(),
	})
	.passthrough();
export type TextMessageEndEvent = z.infer<typeof textMessageEndSchema>;

// --- Tool calls ------------------------------------------------------------

export const toolCallStartSchema = z
	.object({
		...baseEventShape,
		type: z.literal(AGUIEventType.TOOL_CALL_START),
		toolCallId: z.string(),
		toolCallName: z.string(),
		parentMessageId: z.string().optional(),
	})
	.passthrough();
export type ToolCallStartEvent = z.infer<typeof toolCallStartSchema>;

export const toolCallArgsSchema = z
	.object({
		...baseEventShape,
		type: z.literal(AGUIEventType.TOOL_CALL_ARGS),
		toolCallId: z.string(),
		delta: z.string(),
	})
	.passthrough();
export type ToolCallArgsEvent = z.infer<typeof toolCallArgsSchema>;

export const toolCallEndSchema = z
	.object({
		...baseEventShape,
		type: z.literal(AGUIEventType.TOOL_CALL_END),
		toolCallId: z.string(),
	})
	.passthrough();
export type ToolCallEndEvent = z.infer<typeof toolCallEndSchema>;

/**
 * TOOL_CALL_RESULT is the server-side (MCP capability tool) path: the tool ran
 * inside ZAQ and the result returns over SSE — no browser round-trip.
 */
export const toolCallResultSchema = z
	.object({
		...baseEventShape,
		type: z.literal(AGUIEventType.TOOL_CALL_RESULT),
		messageId: z.string(),
		toolCallId: z.string(),
		content: z.string(),
		role: z.literal("tool").optional(),
	})
	.passthrough();
export type ToolCallResultEvent = z.infer<typeof toolCallResultSchema>;

// --- State / custom side-data ---------------------------------------------

export const stateSnapshotSchema = z
	.object({
		...baseEventShape,
		type: z.literal(AGUIEventType.STATE_SNAPSHOT),
		snapshot: z.unknown(),
	})
	.passthrough();
export type StateSnapshotEvent = z.infer<typeof stateSnapshotSchema>;

/**
 * CUSTOM carries ZAQ-specific side-data: citations, KG entities, widget
 * payloads. `name` discriminates the payload kind so the adapter can route to
 * `source-url` (citations) vs `data-zaqEvent` (everything else).
 */
export const customEventSchema = z
	.object({
		...baseEventShape,
		type: z.literal(AGUIEventType.CUSTOM),
		name: z.string(),
		value: z.unknown(),
	})
	.passthrough();
export type CustomEvent = z.infer<typeof customEventSchema>;

// ---------------------------------------------------------------------------
// Discriminated union over the whole subset.
// ---------------------------------------------------------------------------

export const aguiEventSchema = z.discriminatedUnion("type", [
	runStartedSchema,
	runFinishedSchema,
	runErrorSchema,
	stepStartedSchema,
	stepFinishedSchema,
	textMessageStartSchema,
	textMessageContentSchema,
	textMessageEndSchema,
	toolCallStartSchema,
	toolCallArgsSchema,
	toolCallEndSchema,
	toolCallResultSchema,
	stateSnapshotSchema,
	customEventSchema,
]);
export type AGUIEvent = z.infer<typeof aguiEventSchema>;

// ---------------------------------------------------------------------------
// Request body — RunAgentInput + Tool + Context (ag-ui core/src/types.ts).
// This is what the client POSTs to the ZAQ AG-UI endpoint.
// ---------------------------------------------------------------------------

/**
 * Frontend (page) tool advertised per-turn. `parameters` is a JSON-Schema
 * object; `metadata.a2ui` carries the A2UI rendering schema for render_widget.
 */
export const aguiToolSchema = z.object({
	name: z.string(),
	description: z.string(),
	parameters: z.record(z.string(), z.unknown()),
	metadata: z.record(z.string(), z.unknown()).optional(),
});
export type AGUITool = z.infer<typeof aguiToolSchema>;

export const aguiContextSchema = z.object({
	description: z.string(),
	value: z.string(),
});
export type AGUIContext = z.infer<typeof aguiContextSchema>;

/**
 * HITL resume entry — one per pending interrupt, sent on the next run to
 * unblock a waiting ZAQ workflow (POST /ag-ui/runs/:runId/resume).
 */
export const aguiResumeEntrySchema = z.object({
	interruptId: z.string(),
	status: z.enum(["resolved", "cancelled"]),
	payload: z.unknown().optional(),
});
export type AGUIResumeEntry = z.infer<typeof aguiResumeEntrySchema>;

export const runAgentInputSchema = z.object({
	threadId: z.string(),
	runId: z.string(),
	parentRunId: z.string().optional(),
	state: z.unknown(),
	messages: z.array(aguiMessageSchema),
	tools: z.array(aguiToolSchema),
	context: z.array(aguiContextSchema),
	forwardedProps: z.unknown(),
	resume: z.array(aguiResumeEntrySchema).optional(),
});
export type RunAgentInput = z.infer<typeof runAgentInputSchema>;
