# Synthetic Persona: Team End User / New Hire (Asker)

## Subagent Plan
- Subagent name: `subagent_team_asker_experience`
- Objective: ensure employees can quickly get trusted answers with sources and provide feedback when quality is off.
- Scope: chat discovery, query submission, source validation, feedback capture, and chat reset behavior.
- Primary UI surfaces: `/bo/playground`, `/bo/preview/*path`, `/bo/files/*path`.
- Expected deliverable from this subagent: high-confidence user journeys that prove answer usefulness, trust, and usability.

## Top Journeys

### Journey 1: First question from suggestion to cited answer
Sequence of pages visited:
1. `/bo/login`
2. `/bo/playground`
3. `/bo/preview/:path` (or `/bo/files/:path` depending on source extension)

| Page visited | Elements seen | Elements interacted with |
| --- | --- | --- |
| `/bo/login` | Username/password inputs, submit CTA | Authenticate and enter BO |
| `/bo/playground` | Suggestion chips `#suggestion-0..3`, chat input `#chat-input`, send form `#chat-form`, status timeline (validating/retrieving/answering), chat stream `#chat-messages`, source chips under assistant answer | Click a suggestion chip, submit message, wait for answer, click one source chip |
| `/bo/preview/:path` or `/bo/files/:path` | Rendered source document or raw file content | Validate that cited content supports the answer |

### Journey 2: Multi-turn follow-up and confidence-aware reading
Sequence of pages visited:
1. `/bo/playground`

| Page visited | Elements seen | Elements interacted with |
| --- | --- | --- |
| `/bo/playground` | Existing chat context, confidence percentage bar, copy action on messages, assistant/user bubbles | Ask follow-up question in same thread, inspect confidence bar, click copy action on assistant answer, continue with another follow-up |

### Journey 3: Negative feedback loop and conversation recovery
Sequence of pages visited:
1. `/bo/playground`

| Page visited | Elements seen | Elements interacted with |
| --- | --- | --- |
| `/bo/playground` | Thumbs up/down actions on assistant messages, feedback modal `#feedback-modal`, reason chips, free-text feedback textarea, submit CTA `#submit-feedback-button`, clear CTA `#clear-chat-button` | Click negative feedback, select one or more reasons, add optional comment, submit feedback, then clear chat and start a new query |

### Journey 4: Multilingual query confidence check
Sequence of pages visited:
1. `/bo/playground`
2. `/bo/preview/:path` (source validation)

| Page visited | Elements seen | Elements interacted with |
| --- | --- | --- |
| `/bo/playground` | Input area, thinking statuses, answer body, source chips | Submit a non-English question (for example Arabic/French), verify response appears with citations |
| `/bo/preview/:path` | Source content panel | Confirm source links remain useful and relevant for multilingual outputs |
