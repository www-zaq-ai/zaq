import { describe, expect, it } from "vitest";
import { aguiToUIMessageStream } from "../adapter";
import type { AGUIEvent } from "../agui-events";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function collect<T>(stream: ReadableStream<T>): Promise<T[]> {
	const out: T[] = [];
	const reader = stream.getReader();
	for (;;) {
		const { done, value } = await reader.read();
		if (done) break;
		out.push(value);
	}
	return out;
}

async function* scripted(events: AGUIEvent[]): AsyncIterable<AGUIEvent> {
	for (const event of events) {
		yield event;
	}
}

function textDeltas(chunks: { type: string }[]): string[] {
	return chunks
		.filter(
			(c): c is { type: "text-delta"; id: string; delta: string } =>
				c.type === "text-delta",
		)
		.map((c) => c.delta);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("aguiToUIMessageStream", () => {
	it("emits start first and finish last for a normal run", async () => {
		const events: AGUIEvent[] = [
			{ type: "RUN_STARTED", threadId: "t1", runId: "run-1" },
			{ type: "TEXT_MESSAGE_START", messageId: "m1", role: "assistant" },
			{ type: "TEXT_MESSAGE_CONTENT", messageId: "m1", delta: "Hello." },
			{ type: "TEXT_MESSAGE_END", messageId: "m1" },
			{
				type: "RUN_FINISHED",
				threadId: "t1",
				runId: "run-1",
				outcome: { type: "success" },
			},
		];

		const chunks = await collect(aguiToUIMessageStream(scripted(events)));

		expect(chunks.at(0)).toMatchObject({ type: "start", messageId: "run-1" });
		expect(chunks.at(-1)).toMatchObject({ type: "finish" });
	});

	it("forwards each streamed TEXT_MESSAGE_CONTENT delta 1:1 as a text-delta", async () => {
		const parts = ["The quick ", "brown fox ", "jumps."];
		const events: AGUIEvent[] = [
			{ type: "RUN_STARTED", threadId: "t1", runId: "run-1" },
			{ type: "TEXT_MESSAGE_START", messageId: "m1", role: "assistant" },
			...parts.map(
				(delta): AGUIEvent => ({
					type: "TEXT_MESSAGE_CONTENT",
					messageId: "m1",
					delta,
				}),
			),
			{ type: "TEXT_MESSAGE_END", messageId: "m1" },
			{
				type: "RUN_FINISHED",
				threadId: "t1",
				runId: "run-1",
				outcome: { type: "success" },
			},
		];

		const deltas = textDeltas(await collect(aguiToUIMessageStream(scripted(events))));

		// Each token is forwarded as its own frame; concatenation reconstructs
		// the answer exactly (delta boundaries may shift around whitespace).
		expect(deltas.length).toBeGreaterThan(1);
		expect(deltas.join("")).toBe("The quick brown fox jumps.");
	});

	it("maps RUN_ERROR to an error chunk then finishes without throwing", async () => {
		const events: AGUIEvent[] = [
			{ type: "RUN_STARTED", threadId: "t1", runId: "run-1" },
			{ type: "RUN_ERROR", message: "upstream rate limit exceeded" },
		];

		const chunks = await collect(aguiToUIMessageStream(scripted(events)));

		expect(chunks).toContainEqual({
			type: "error",
			errorText: "upstream rate limit exceeded",
		});
		expect(chunks.at(-1)).toMatchObject({ type: "finish" });
	});

	it("strips ZAQ provenance markers from answer text", async () => {
		const events: AGUIEvent[] = [
			{ type: "RUN_STARTED", threadId: "t1", runId: "run-1" },
			{ type: "TEXT_MESSAGE_START", messageId: "m1", role: "assistant" },
			{
				type: "TEXT_MESSAGE_CONTENT",
				messageId: "m1",
				delta: "Hello [[source:doc-42]] world [[memory:ctx-7]].",
			},
			{ type: "TEXT_MESSAGE_END", messageId: "m1" },
			{
				type: "RUN_FINISHED",
				threadId: "t1",
				runId: "run-1",
				outcome: { type: "success" },
			},
		];

		const deltas = textDeltas(await collect(aguiToUIMessageStream(scripted(events))));
		expect(deltas.join("")).toBe("Hello world.");
	});

	it("strips a provenance marker split across streamed deltas", async () => {
		const events: AGUIEvent[] = [
			{ type: "RUN_STARTED", threadId: "t1", runId: "run-1" },
			{ type: "TEXT_MESSAGE_START", messageId: "m1", role: "assistant" },
			{ type: "TEXT_MESSAGE_CONTENT", messageId: "m1", delta: "Hello [[sou" },
			{
				type: "TEXT_MESSAGE_CONTENT",
				messageId: "m1",
				delta: "rce:doc-42]] world",
			},
			{ type: "TEXT_MESSAGE_END", messageId: "m1" },
			{
				type: "RUN_FINISHED",
				threadId: "t1",
				runId: "run-1",
				outcome: { type: "success" },
			},
		];

		const deltas = textDeltas(await collect(aguiToUIMessageStream(scripted(events))));
		expect(deltas.join("")).toBe("Hello world");
		expect(deltas.join("")).not.toContain("[[");
	});

	it("emits source-url for citation CUSTOM events", async () => {
		const events: AGUIEvent[] = [
			{ type: "RUN_STARTED", threadId: "t1", runId: "run-1" },
			{
				type: "CUSTOM",
				name: "citation",
				value: {
					url: "https://example.com/doc",
					title: "Example Doc",
					sourceId: "src-1",
				},
			},
			{
				type: "RUN_FINISHED",
				threadId: "t1",
				runId: "run-1",
				outcome: { type: "success" },
			},
		];

		const chunks = await collect(aguiToUIMessageStream(scripted(events)));

		expect(chunks).toContainEqual({
			type: "source-url",
			sourceId: "src-1",
			url: "https://example.com/doc",
			title: "Example Doc",
		});
	});

	it("emits data-zaqEvent for STATE_SNAPSHOT events", async () => {
		const snapshot = { phase: "retrieving", step: 1 };

		const events: AGUIEvent[] = [
			{ type: "RUN_STARTED", threadId: "t1", runId: "run-1" },
			{ type: "STATE_SNAPSHOT", snapshot },
			{
				type: "RUN_FINISHED",
				threadId: "t1",
				runId: "run-1",
				outcome: { type: "success" },
			},
		];

		const chunks = await collect(aguiToUIMessageStream(scripted(events)));

		const stateChunk = chunks.find(
			(c) =>
				c.type === "data-zaqEvent" &&
				(c as { data: { kind: string } }).data?.kind === "state-snapshot",
		);
		expect(stateChunk).toBeDefined();
		expect(
			(stateChunk as { data: { kind: string; value: unknown } }).data.value,
		).toEqual(snapshot);
	});

	it("gracefully finishes when the event stream ends without RUN_FINISHED", async () => {
		const events: AGUIEvent[] = [
			{ type: "RUN_STARTED", threadId: "t1", runId: "run-1" },
			{ type: "TEXT_MESSAGE_START", messageId: "m1", role: "assistant" },
			{ type: "TEXT_MESSAGE_END", messageId: "m1" },
			// No RUN_FINISHED
		];

		const chunks = await collect(aguiToUIMessageStream(scripted(events)));

		expect(chunks.at(0)).toMatchObject({ type: "start" });
		expect(chunks.at(-1)).toMatchObject({ type: "finish", finishReason: "stop" });
	});
});
