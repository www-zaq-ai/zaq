# Synthetic Persona: Knowledge Ops Lead (Curator)

## Subagent Plan

- Subagent name: `subagent_knowledge_ops_curator`
- Objective: validate that ZAQ can ingest, organize, and keep knowledge fresh so answers stay current.
- Scope: ingestion workflows, prompt governance, and answer verification loops.
- Primary UI surfaces: `/bo/ingestion`, `/bo/prompt-templates`, `/bo/playground`, `/bo/preview/*path`.
- Expected deliverable from this subagent: a page-by-page journey map with visible UI elements and explicit user interactions for E2E automation.

## Top Journeys

### Journey 1: Ingest new knowledge and confirm it is queryable

Sequence of pages visited:

1. `/bo/login`
2. `/bo/ingestion`
3. `/bo/preview/:path`
4. `/bo/playground`

| Page visited        | Elements seen                                                                                                    | Elements interacted with                                                                                                             |
| ------------------- | ---------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `/bo/login`         | Login card, username input `input[name="username"]`, password input `input[name="password"]`, submit CTA         | Fill username/password, click `Sign In to Dashboard`                                                                                 |
| `/bo/ingestion`     | File Browser area, upload form `#upload-form`, mode toggle (`async`/`inline`), jobs panel, `Ingest Selected` CTA | Click `Add Raw MD`, fill `#raw-filename-input` + `textarea[name="content"]`, save file, select row checkbox, click `Ingest Selected` |
| `/bo/preview/:path` | Rendered markdown/text viewer, file metadata (size/modified), raw link                                           | Click `Raw` to verify source content and file rendering                                                                              |
| `/bo/playground`    | Chat stream `#chat-messages`, input `#chat-input`, send form `#chat-form`, answer source chips                   | Ask question about newly ingested file, submit, click a source chip to validate grounding                                            |

### Journey 2: Maintain file hierarchy and stale-document hygiene

Sequence of pages visited:

1. `/bo/ingestion`
2. `/bo/preview/:path`

| Page visited        | Elements seen                                                                                                                                       | Elements interacted with                                                                                                                                                                                 |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/bo/ingestion`     | Breadcrumbs (`root` + folder path), list/grid toggle, status badges (`ingested`/`stale`), row hover actions (move/rename/delete), bulk delete modal | Create folder via `New Folder` (`#new-folder-input`), navigate with breadcrumbs, rename a file, move item, edit file content, observe stale badge after update, run bulk delete with selected checkboxes |
| `/bo/preview/:path` | File content panel and metadata                                                                                                                     | Re-open modified file and verify the update is visible before re-ingesting                                                                                                                               |

### Journey 3: Tune prompt behavior and verify answer quality loop

Sequence of pages visited:

1. `/bo/prompt-templates`
2. `/bo/playground`
3. `/bo/preview/:path`

| Page visited           | Elements seen                                                                                               | Elements interacted with                                                                             |
| ---------------------- | ----------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `/bo/prompt-templates` | Template tabs by slug, active toggle switch, body editor `textarea[name="prompt_template[body]"]`, save CTA | Open retrieval/answering template tab, edit prompt body, toggle active state if needed, click `Save` |
| `/bo/playground`       | Thinking states (`Validating`, `Retrieving`, `Answering`), confidence indicator, source chips               | Ask the same control question pre/post prompt change and compare response quality/confidence         |
| `/bo/preview/:path`    | Source file view                                                                                            | Open cited source and confirm answer alignment with underlying knowledge                             |
