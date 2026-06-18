/**
 * Core stream map: AG-UI events -> AI SDK `UIMessageChunk`s.
 *
 * Like `@ai-sdk/langchain` `toUIMessageStream`: emit a mandatory `start` chunk
 * first, translate each AG-UI event (see the switch below for the full map),
 * then emit a mandatory `finish` chunk last. Without `start` the UI never
 * leaves status `submitted`; without `finish` it stays stuck in `streaming`.
 *
 * ZAQ token-streams its answer: each `TEXT_MESSAGE_CONTENT` carries an
 * incremental delta, forwarded 1:1 as a `text-delta`. Inline provenance markers
 * (`[[source:…]]`) are stripped by a stateful stripper that survives a marker
 * split across delta boundaries.
 */

import {
	createUIMessageStream,
	type UIMessage,
	type UIMessageChunk,
	type UIMessageStreamWriter,
} from "ai";
import {
	type AGUIEvent,
	AGUIEventType,
	type AGUIInterrupt,
} from "./agui-events";

// ---------------------------------------------------------------------------
// Data-part types surfaced on the UIMessage data[] channel.
// ---------------------------------------------------------------------------

/**
 * Typed envelope for every ZAQ-specific data part emitted on the
 * `data-zaqEvent` channel. Consumers narrow on `kind` to handle
 * specific payloads (state snapshots, custom widget events, etc.).
 */
export interface ZaqEventDataPart {
	kind: string;
	value: unknown;
}

/**
 * Data part emitted when ZAQ returns a HITL interrupt. Carries one or more
 * pending interrupt descriptors; the client should surface an approval prompt
 * for each before resuming the run.
 */
export interface ZaqInterruptDataPart {
	kind: "interrupt";
	interrupts: AGUIInterrupt[];
}

// ---------------------------------------------------------------------------
// Public API.
// ---------------------------------------------------------------------------

export interface AguiToUIMessageStreamOptions {
	/**
	 * Called for any AG-UI event not handled by the mapping table. Useful for
	 * debug logging or forwarding proprietary ZAQ events to analytics.
	 */
	onUnknownEvent?: (event: Extract<AGUIEvent, { type: "CUSTOM" }>) => void;
	/**
	 * Seed the message ID counter. Defaults to a `zaq-N` sequence. Override in
	 * tests to get deterministic IDs.
	 */
	generateId?: () => string;
}

// ---------------------------------------------------------------------------
// ZAQ provenance markers.
//
// ZAQ's answer text contains inline provenance annotations of the form
// `[[source:...]]` / `[[memory:...]]` — retrieval-pipeline routing tags, not
// answer text. They must be stripped before forwarding to the UI.
//
// Because ZAQ token-streams, a marker can arrive split across deltas
// (`...[[so` + `urce:doc]]...`). A stateless per-delta `replace` would leak the
// halves, so `createMarkerStripper` buffers a trailing run that could still grow
// into a marker, emits everything proven safe, and flushes the remainder once
// the text part closes.
// ---------------------------------------------------------------------------

const ZAQ_PROVENANCE_MARKER_RE = /\s*\[\[(?:source|memory):[^\]]*\]\]/g;

interface MarkerStripper {
	/** Push a streamed delta; returns the text safe to emit now. */
	push(delta: string): string;
	/** Drain whatever is still buffered once the stream ends. */
	flush(): string;
}

function createMarkerStripper(): MarkerStripper {
	let buffer = "";

	const drainSafe = (atEnd: boolean): string => {
		buffer = buffer.replace(ZAQ_PROVENANCE_MARKER_RE, "");
		if (atEnd) {
			const out = buffer;
			buffer = "";
			return out;
		}
		// Hold back from the last unclosed `[[` (or a lone trailing `[`): that
		// tail could still grow into a complete marker on a later delta.
		let hold = buffer.length;
		const lastOpen = buffer.lastIndexOf("[[");
		if (lastOpen !== -1 && !buffer.slice(lastOpen).includes("]]")) {
			hold = lastOpen;
		} else if (buffer.endsWith("[")) {
			hold = buffer.length - 1;
		}
		// Always hold back a trailing whitespace run: it may precede a marker
		// that opens in the next delta, and the marker regex eats one leading
		// space. Concatenating all emitted deltas still reconstructs the answer
		// exactly (minus complete markers); only the delta boundaries shift.
		while (hold > 0 && /\s/.test(buffer.charAt(hold - 1))) {
			hold -= 1;
		}
		const out = buffer.slice(0, hold);
		buffer = buffer.slice(hold);
		return out;
	};

	return {
		push(delta: string): string {
			buffer += delta;
			return drainSafe(false);
		},
		flush(): string {
			return drainSafe(true);
		},
	};
}

// ---------------------------------------------------------------------------
// Internal helpers.
// ---------------------------------------------------------------------------

/**
 * Parse accumulated TOOL_CALL_ARGS JSON for a finished tool call. Returns
 * `undefined` when no args were streamed, the parsed object on success, or
 * `{ raw: args }` when the payload is malformed/partial — never throws, so a
 * bad tool call degrades gracefully instead of tearing down the stream.
 */
function parseToolCallArgs(args: string | undefined): unknown {
	if (!args) return undefined;
	try {
		return JSON.parse(args);
	} catch {
		return { raw: args };
	}
}

/** CUSTOM event names that the adapter maps to `source-url` citation parts. */
const CITATION_CUSTOM_NAMES = new Set([
	"citation",
	"source",
	"cite",
	"reference",
]);

// ---------------------------------------------------------------------------
// Core transform.
// ---------------------------------------------------------------------------

/**
 * Adapt an `AsyncIterable<AGUIEvent>` from a ZAQ AG-UI endpoint into a
 * `ReadableStream<UIMessageChunk>` that the Vercel AI SDK's `useChat` hook
 * (and `createUIMessageStreamResponse`) can consume directly.
 *
 * @param events - The event stream from `aguiHttpAgentEventStream` or any
 *   other source that yields `AGUIEvent` objects.
 * @param options - Optional: unknown-event hook, ID generator.
 * @returns A `ReadableStream<UIMessageChunk>` — pass it to
 *   `createUIMessageStreamResponse` in your proxy route.
 */
export function aguiToUIMessageStream<UI_MESSAGE extends UIMessage = UIMessage>(
	events: AsyncIterable<AGUIEvent>,
	options: AguiToUIMessageStreamOptions = {},
): ReadableStream<UIMessageChunk> {
	const generateId = options.generateId ?? createCounterId();

	return createUIMessageStream<UI_MESSAGE>({
		execute: async ({ writer }: { writer: UIMessageStreamWriter<UI_MESSAGE> }) => {
			const write = (chunk: UIMessageChunk): void =>
				writer.write(chunk as Parameters<typeof writer.write>[0]);

			let runId: string | undefined;
			let started = false;
			// One stripper per open text part, keyed by messageId. Flushed on
			// TEXT_MESSAGE_END or when the run closes, so a marker still mid-buffer
			// never leaks into the final answer.
			const openText = new Map<string, MarkerStripper>();
			const toolCalls = new Map<string, { name: string; args: string }>();

			function ensureStarted(id?: string): void {
				if (started) return;
				started = true;
				// messageId <- runId (mirrors how @ai-sdk/langchain uses run_id as id).
				write({ type: "start", messageId: id ?? runId ?? generateId() });
			}

			const closeOpenText = (): void => {
				for (const [id, stripper] of openText) {
					const tail = stripper.flush();
					if (tail) {
						write({ type: "text-delta", id, delta: tail });
					}
					write({ type: "text-end", id });
				}
				openText.clear();
			};

			try {
				for await (const event of events) {
					switch (event.type) {
						case AGUIEventType.RUN_STARTED: {
							runId = event.runId;
							ensureStarted(event.runId);
							break;
						}

						case AGUIEventType.STEP_STARTED: {
							write({ type: "start-step" });
							break;
						}

						case AGUIEventType.STEP_FINISHED: {
							write({ type: "finish-step" });
							break;
						}

						case AGUIEventType.TEXT_MESSAGE_START: {
							ensureStarted();
							openText.set(event.messageId, createMarkerStripper());
							write({ type: "text-start", id: event.messageId });
							break;
						}

						case AGUIEventType.TEXT_MESSAGE_CONTENT: {
							ensureStarted();
							// Forward each streamed delta 1:1 as a text-delta, stripping
							// any inline provenance markers (handles markers split across
							// deltas). Tolerate a missing TEXT_MESSAGE_START.
							let stripper = openText.get(event.messageId);
							if (!stripper) {
								stripper = createMarkerStripper();
								openText.set(event.messageId, stripper);
							}
							const clean = stripper.push(event.delta);
							if (clean) {
								write({
									type: "text-delta",
									id: event.messageId,
									delta: clean,
								});
							}
							break;
						}

						case AGUIEventType.TEXT_MESSAGE_END: {
							const stripper = openText.get(event.messageId);
							const tail = stripper?.flush() ?? "";
							if (tail) {
								write({ type: "text-delta", id: event.messageId, delta: tail });
							}
							openText.delete(event.messageId);
							write({ type: "text-end", id: event.messageId });
							break;
						}

						case AGUIEventType.TOOL_CALL_START: {
							ensureStarted();
							toolCalls.set(event.toolCallId, {
								name: event.toolCallName,
								args: "",
							});
							// REQUIRED for remote-agent dynamic tools (dynamic: true).
							write({
								type: "tool-input-start",
								toolCallId: event.toolCallId,
								toolName: event.toolCallName,
								dynamic: true,
							});
							break;
						}

						case AGUIEventType.TOOL_CALL_ARGS: {
							const acc = toolCalls.get(event.toolCallId);
							if (acc) {
								acc.args += event.delta;
							}
							write({
								type: "tool-input-delta",
								toolCallId: event.toolCallId,
								inputTextDelta: event.delta,
							});
							break;
						}

						case AGUIEventType.TOOL_CALL_END: {
							const acc = toolCalls.get(event.toolCallId);
							write({
								type: "tool-input-available",
								toolCallId: event.toolCallId,
								toolName: acc?.name ?? "",
								input: parseToolCallArgs(acc?.args),
								dynamic: true,
							});
							toolCalls.delete(event.toolCallId);
							break;
						}

						case AGUIEventType.TOOL_CALL_RESULT: {
							// Server-side (MCP capability) tool result: the tool ran
							// inside ZAQ and the result returned over SSE — no browser
							// round-trip.
							write({
								type: "tool-output-available",
								toolCallId: event.toolCallId,
								output: event.content,
							});
							break;
						}

						case AGUIEventType.STATE_SNAPSHOT: {
							// Emit as a data-zaqEvent data part.
							write({
								type: "data-zaqEvent",
								id: generateId(),
								data: {
									kind: "state-snapshot",
									value: event.snapshot,
								} satisfies ZaqEventDataPart,
								transient: false,
							});
							break;
						}

						case AGUIEventType.CUSTOM: {
							emitCustom(write, generateId, event, options);
							break;
						}

						case AGUIEventType.RUN_ERROR: {
							closeOpenText();
							write({ type: "error", errorText: event.message });
							write({ type: "finish", finishReason: "error" });
							return;
						}

						case AGUIEventType.RUN_FINISHED: {
							if (event.outcome?.type === "interrupt") {
								// HITL path: surface the interrupt descriptors so the
								// client can render an approval prompt.
								write({
									type: "data-zaqEvent",
									id: generateId(),
									data: {
										kind: "interrupt",
										interrupts: event.outcome.interrupts,
									} satisfies ZaqInterruptDataPart,
									transient: false,
								});
							}
							// LAST CHUNK.
							closeOpenText();
							write({ type: "finish", finishReason: "stop" });
							return;
						}

						default: {
							// Unknown event type — pass to the caller's hook if provided.
							options.onUnknownEvent?.(
								event as Extract<AGUIEvent, { type: "CUSTOM" }>,
							);
							break;
						}
					}
				}

				// Stream exhausted without a RUN_FINISHED event — still close out
				// gracefully so the UI doesn't get stuck in `streaming`.
				if (!started) {
					write({ type: "start", messageId: generateId() });
				}
				closeOpenText();
				write({ type: "finish", finishReason: "stop" });
			} catch (error) {
				closeOpenText();
				write({
					type: "error",
					errorText: error instanceof Error ? error.message : String(error),
				});
				write({ type: "finish", finishReason: "error" });
			}
		},

		onError: (error) =>
			error instanceof Error ? error.message : String(error),
	}) as ReadableStream<UIMessageChunk>;
}

// ---------------------------------------------------------------------------
// CUSTOM event routing.
// ---------------------------------------------------------------------------

/**
 * Route a CUSTOM event to either a `source-url` citation part or a generic
 * `data-zaqEvent` data part, based on the event `name`.
 */
function emitCustom(
	write: (chunk: UIMessageChunk) => void,
	generateId: () => string,
	event: Extract<AGUIEvent, { type: "CUSTOM" }>,
	options: AguiToUIMessageStreamOptions,
): void {
	if (CITATION_CUSTOM_NAMES.has(event.name.toLowerCase())) {
		const citation = event.value as {
			url?: string;
			title?: string;
			sourceId?: string;
		} | null;
		if (citation?.url) {
			write({
				type: "source-url",
				sourceId: citation.sourceId ?? generateId(),
				url: citation.url,
				title: citation.title,
			});
			return;
		}
	}

	// Unknown custom event — pass to caller, then emit as a data part so
	// the stream stays in sync.
	options.onUnknownEvent?.(event);
	write({
		type: "data-zaqEvent",
		id: generateId(),
		data: { kind: event.name, value: event.value } satisfies ZaqEventDataPart,
		transient: false,
	});
}

// ---------------------------------------------------------------------------
// ID generator.
// ---------------------------------------------------------------------------

function createCounterId(): () => string {
	let n = 0;
	return () => `zaq-${++n}`;
}
