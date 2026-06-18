/**
 * Official AG-UI client transport.
 *
 * Wraps `@ag-ui/client`'s `HttpAgent`, which POSTs the `RunAgentInput`,
 * decodes the `text/event-stream` response, and validates each frame against
 * the official `@ag-ui/core` `EventSchemas` — yielding a typed
 * `Observable<BaseEvent>`.
 *
 * We bridge that rxjs Observable into an `AsyncIterable<BaseEvent>` so the
 * existing `aguiToUIMessageStream` mapper (provenance-marker handling +
 * event translation) consumes it unchanged. The official `BaseEvent` shapes
 * are field-compatible with the event types the mapper already reads
 * (`toolCallId`, `toolCallName`, `messageId`, `delta`, `snapshot`, `name`,
 * `value`), so the mapper needs no change.
 *
 * Note: `EventSchemas.parse` strips fields not in the official spec — notably
 * ZAQ's non-standard `RUN_FINISHED.outcome` (HITL). That path is dormant in
 * the current release; if HITL ships it must use the official interrupt
 * mechanism rather than a custom field.
 */

import { HttpAgent } from "@ag-ui/client";
import type {
	RunAgentInput as AgUiRunAgentInput,
	BaseEvent,
} from "@ag-ui/core";
import type { RunAgentInput } from "./agui-events";

export interface AguiHttpAgentOptions {
	/** The `RunAgentInput` the client POSTs (built by the proxy route). */
	input: RunAgentInput;
	/** Request abort signal — wired to the agent so a client disconnect tears
	 * down the upstream ZAQ request. */
	signal?: AbortSignal;
	/** Bearer token held server-side; never reaches the browser. */
	token: string;
	/** Full AG-UI runs endpoint, e.g. `http://localhost:4100/ag-ui/runs`. */
	url: string;
}

/**
 * Bridge an rxjs `Observable` into a pull-based `AsyncIterable`. Buffers
 * events that arrive faster than the consumer drains them; surfaces errors and
 * completion. Unsubscribes when the consumer stops (return/throw) so the
 * upstream HTTP request is cancelled.
 */
async function* observableToAsyncIterable<T>(observable: {
	subscribe(observer: {
		next: (value: T) => void;
		error: (err: unknown) => void;
		complete: () => void;
	}): { unsubscribe: () => void };
}): AsyncIterable<T> {
	const queue: T[] = [];
	let wake: (() => void) | null = null;
	let done = false;
	let failure: { error: unknown } | null = null;

	const subscription = observable.subscribe({
		next: (value) => {
			queue.push(value);
			wake?.();
			wake = null;
		},
		error: (error) => {
			failure = { error };
			wake?.();
			wake = null;
		},
		complete: () => {
			done = true;
			wake?.();
			wake = null;
		},
	});

	try {
		while (true) {
			if (queue.length > 0) {
				yield queue.shift() as T;
				continue;
			}
			if (failure) {
				// Cast: TS's control-flow analysis narrows `failure` to `never`
				// here because the assignment lives inside the subscribe closure.
				throw (failure as { error: unknown }).error;
			}
			if (done) {
				return;
			}
			await new Promise<void>((resolve) => {
				wake = resolve;
			});
		}
	} finally {
		subscription.unsubscribe();
	}
}

/**
 * Run a ZAQ AG-UI agent over HTTP via the official `@ag-ui/client` and yield
 * the decoded, validated `BaseEvent` stream.
 */
export function aguiHttpAgentEventStream(
	options: AguiHttpAgentOptions,
): AsyncIterable<BaseEvent> {
	const agent = new HttpAgent({
		url: options.url,
		headers: { Authorization: `Bearer ${options.token}` },
	});

	if (options.signal) {
		if (options.signal.aborted) {
			agent.abortRun();
		} else {
			options.signal.addEventListener("abort", () => agent.abortRun(), {
				once: true,
			});
		}
	}

	// `run` is the low-level method: POST + SSE decode + per-frame validation.
	// Our `RunAgentInput` is field-compatible with the official type.
	const events$ = agent.run(options.input as unknown as AgUiRunAgentInput);
	return observableToAsyncIterable<BaseEvent>(events$);
}
