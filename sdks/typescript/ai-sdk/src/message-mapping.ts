/**
 * UIMessage -> AG-UI Message conversion.
 *
 * The AI SDK's `UIMessage` carries a `parts[]` array (text, reasoning, tool,
 * source, file, data, step-start). ZAQ only needs role + flat text, so
 * `toAGUIMessages` flattens the text parts and drops the client-only parts the
 * backend never round-trips — mirroring ag-ui's `prepareRunAgentInput`.
 *
 * Types only from `ai` (`verbatimModuleSyntax` is on), so no runtime `ai`
 * dependency is pulled into this path.
 */

import type { UIMessage } from "ai";
import type { AGUIMessage } from "./agui-events";

type AnyUIMessagePart = UIMessage["parts"][number];

/** Concatenate a UIMessage's text parts; ignore everything else. */
function flattenTextContent(message: UIMessage): string {
	let content = "";
	for (const part of message.parts as AnyUIMessagePart[]) {
		if (part.type === "text") {
			content += part.text;
		}
	}
	return content;
}

/**
 * Convert the AI SDK conversation history into AG-UI messages for
 * `RunAgentInput.messages`.
 */
export function toAGUIMessages(uiMessages: UIMessage[]): AGUIMessage[] {
	return uiMessages.map((message) => ({
		id: message.id,
		role: message.role,
		content: flattenTextContent(message),
	}));
}
