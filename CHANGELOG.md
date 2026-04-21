# Changelog

## [0.7.3](https://github.com/www-zaq-ai/zaq/compare/v0.7.2...v0.7.3) (2026-04-21)


### Bug Fixes

* **chat:** add date separators to message list, conversation detail, and chat sidebar ([4136a0f](https://github.com/www-zaq-ai/zaq/commit/4136a0f68109aa6e8f4ad144cbba995d8b99dcd3))
* **chat:** persist welcome message in conversation history so loaded chats keep the original date ([08f8aa4](https://github.com/www-zaq-ai/zaq/commit/08f8aa4a4bb40166b3ff05eff9286a1d3cb47d33))
* **e2e:** alias nested E2E modules and fix alias ordering in Reset ([0b04ec7](https://github.com/www-zaq-ai/zaq/commit/0b04ec7a4602e57bd0e15eb221924c6514de6880))
* **e2e:** stabilize Playwright suite with /e2e/reset endpoint, LiveView settle waits, and server-side mtime touch ([d14f203](https://github.com/www-zaq-ai/zaq/commit/d14f2033acc3b1be31d1a7bf94fb22a148b54783))
* **ingestion:** deduplicate uploaded filenames using OS-style (n) suffix ([1dbd323](https://github.com/www-zaq-ai/zaq/commit/1dbd3238f4d503bd79edebbb6ade2e0cb1cddbdc))
* **ingestion:** restore overwrite behaviour for raw saves; add save_file/3, tests, and e2e dedup upload ([fc42061](https://github.com/www-zaq-ai/zaq/commit/fc420614982e6bb2c6499781bf23f84daa2fcc88))
* **ingestion:** skip language filter for simple-fallback BM25 queries to prevent missed results ([6c64763](https://github.com/www-zaq-ai/zaq/commit/6c64763a17ec02b19b140d99f3b1ead2aae3c401))
* **migration:** auto-migrate pgvector → paradedb in zaq-local.sh with full data preservation ([39ef775](https://github.com/www-zaq-ai/zaq/commit/39ef7751da7f0b382978765b701dc2a5569a4761))
* **telemetry:** anchor dashboard_data test timestamps to midday to prevent midnight boundary flake ([2707cf8](https://github.com/www-zaq-ai/zaq/commit/2707cf846d012ca450e57b67960f14c2d9ce1e77))

## [0.7.2](https://github.com/www-zaq-ai/zaq/compare/v0.7.1...v0.7.2) (2026-04-17)


### Bug Fixes

* **assets:** fix ontology_tree hook ([a501646](https://github.com/www-zaq-ai/zaq/commit/a501646c4dc04a3d58609c220472fc67f87de2ab))
* **bo-metrics:** add negative feedback charts and reorder layout ([d38ad1d](https://github.com/www-zaq-ai/zaq/commit/d38ad1df1923f7d97102137087fcad0803cd161d))
* **credentials:** complete migration from old providers config, enable safe deletion of credentials ([1d7d3f7](https://github.com/www-zaq-ai/zaq/commit/1d7d3f7ad9991328e19eb39ee316231808d6a8df))
* **ingestion:** add coverage for noeol reassembly, log_line prefix routing, and default args ([eda1277](https://github.com/www-zaq-ai/zaq/commit/eda127733e6f516a4fe03870f0d6454a6f55c661))
* **ingestion:** add regression guard for strip_local_image_refs stripping /tmp paths from markdown ([3a22c52](https://github.com/www-zaq-ai/zaq/commit/3a22c52e0898368386b94931c7c9fa7c08473cc2))
* **ingestion:** pass endpoint and model opts from system config into image-to-text pipeline ([5f9dc4f](https://github.com/www-zaq-ai/zaq/commit/5f9dc4fd7d38839ddc5294dfe2e32c167a1071cc))
* **ingestion:** replace stale System.cmd helper with Port-based tests covering exit codes, args, ([98e6684](https://github.com/www-zaq-ai/zaq/commit/98e6684107ab7b26fac4f5182762dbad009d175f))
* **ingestion:** rescue ErlangError from Port.open when python executable is missing in CI ([184a038](https://github.com/www-zaq-ai/zaq/commit/184a038ca32a741026e56fa2da690cf965bbba89))
* **ingestion:** strip local image refs from markdown before deleting tmp images ([9d905bf](https://github.com/www-zaq-ai/zaq/commit/9d905bfb93dd5dda5227b7ac83a1037d98d37193))
* **ingestion:** switch Port.open options to correct atom/tuple syntax for stderr_to_stdout and args ([e1495c0](https://github.com/www-zaq-ai/zaq/commit/e1495c043e10afa20572468fa25a1703ddace1fd))
* **ingestion:** use tmp dir for pipeline images and fix preview colspan ([3b0df61](https://github.com/www-zaq-ai/zaq/commit/3b0df61c4a6646b92706057ff297a6f8d6d9ed83))
* **logprobs:** adjust logprobs extraction on newest langchain deps ([e09d21e](https://github.com/www-zaq-ai/zaq/commit/e09d21e16d3119ec7a824bbc34635d6253f71d15))
* **pipeline:** restore :question key in answer_opts so Answering.ask receives the current user message ([b383560](https://github.com/www-zaq-ai/zaq/commit/b383560ddb42b5e2780a5d447384cbf2287f6458))
* **telemetry:** align cursor docs and centralize feedback reasons ([a9a15b8](https://github.com/www-zaq-ai/zaq/commit/a9a15b8b76af21b818baf937a10733f0eaa6d3da))
* **telemetry:** process rollups by point cursor ([d8209f1](https://github.com/www-zaq-ai/zaq/commit/d8209f1f84c43d1c1c1c4767c56be0220f86a233))
* **telemetry:** rebuild feedback metrics by message time ([09584fb](https://github.com/www-zaq-ai/zaq/commit/09584fbb0acb17c1bf1893d35b7f35d8694ca079))
* **telemetry:** repair qa message/no-answer parity and rollup rebuild ([6cab13c](https://github.com/www-zaq-ai/zaq/commit/6cab13c8efa13105802be4391202e2a8ca91249c))
* **ui:** remove overflow-hidden from image-to-text panel, round top corners on header ([82cf85a](https://github.com/www-zaq-ai/zaq/commit/82cf85a046ab78cedcd57966d05fb4b5d45b24d3))

## [0.7.1](https://github.com/www-zaq-ai/zaq/compare/v0.7.0...v0.7.1) (2026-04-11)


### Bug Fixes

* **conversation:** Send typing event to Channels router when retrieval pipeline is activated ([d6dac82](https://github.com/www-zaq-ai/zaq/commit/d6dac820b6898452817d66788c762a9fa5176732))

## [0.7.0](https://github.com/www-zaq-ai/zaq/compare/v0.6.4...v0.7.0) (2026-04-10)


### Features

* **bo:** add conversation history page with person/sender resolution and backfill ([d09ce21](https://github.com/www-zaq-ai/zaq/commit/d09ce217af24931d0214a746611156ba87242d2c))
* **channels:** delete all custom Mattermost code and redirect references to jido_chat_mattermost ([5cb4a4b](https://github.com/www-zaq-ai/zaq/commit/5cb4a4b2c6c754dab95db8bab1f325110073ebb4))
* **channels:** delete Router and remove dispatch_question path ([835f228](https://github.com/www-zaq-ai/zaq/commit/835f22882bfec7c1a9f0372dad8a2a3c79a40dd5))
* **channels:** introduce ChatBridge, ChatBridgeServer, and Conversations.persist_from_incoming ([ec0a9c6](https://github.com/www-zaq-ai/zaq/commit/ec0a9c607a1da5736c453cda75fb6fb00ced53a6))
* **channels:** move SMTP config into channel settings ([800e5e7](https://github.com/www-zaq-ai/zaq/commit/800e5e7c12d1306171afb48398be95a6d97e5c3c))
* **channels:** wire ChatBridgeServer into Channels.Supervisor with DB-driven adapter loading ([11528f5](https://github.com/www-zaq-ai/zaq/commit/11528f514aae2117dcb0b5dd2930bd9ccd6b394e))
* **chat:** Support mardown content from LLM, Support line level source references ([ba1d270](https://github.com/www-zaq-ai/zaq/commit/ba1d270bac61e8a20cee9e01686fe7565bb4228b))
* **chunk:** dispatch :after_embedding_reset hook from reset_table/1 ([8f3312d](https://github.com/www-zaq-ai/zaq/commit/8f3312df5ab0daf68dde63c35c4fe4e466d468c5))
* **communication:** add incoming email through IMAP configuration form and wire it to the channel's supervisor ([9e55700](https://github.com/www-zaq-ai/zaq/commit/9e5570033e7b8d5b4192b345996f4db0d771c35b))
* **communication:** IMAP email receiver architecture ([0cc71d7](https://github.com/www-zaq-ai/zaq/commit/0cc71d7bf6414b12e9df2eb4c227b89ed6e596d2))
* define Zaq.Engine.Messages.Incoming as canonical internal message struct ([807e612](https://github.com/www-zaq-ai/zaq/commit/807e6124ab474c874d27dabb7fdf9e19e397d0d8))
* **deps:** add jido_chat and jido_chat_mattermost dependencies ([446d44b](https://github.com/www-zaq-ai/zaq/commit/446d44b794cbdc184fee6e88bb9393bd6a453d5a))
* **e2e:** add observability endpoints for agent validation ([7d6ae94](https://github.com/www-zaq-ai/zaq/commit/7d6ae94c2e1763a4bcab31dbed820482fe2af5d4))
* **email:** add the implementation for an email:imap adapter to receive emails ([a2ea511](https://github.com/www-zaq-ai/zaq/commit/a2ea511b2f92cdacce20b1d71ab2f6c0a311e3b6))
* **file:** Move preview as in-place popin instead of separate tab ([f43482a](https://github.com/www-zaq-ai/zaq/commit/f43482a467be661a61072015066c28bb9656377b))
* **ingestion:** public tag UI — access column, share modal toggle, grid/list view polish, job filters, sticky header ([7895c2c](https://github.com/www-zaq-ai/zaq/commit/7895c2c420228d1d55ac27266a23d970677e7af7))
* **license:** remove slack/email/rag/multi-tenant features and add knowledge update and document update ([378f11a](https://github.com/www-zaq-ai/zaq/commit/378f11abed5625bf74cd8c59fe0d69d142dc209f))
* **llm:** add Anthropic provider support alongside OpenAI ([dce864b](https://github.com/www-zaq-ai/zaq/commit/dce864bf919e338e36206069f0f5c964ea22548a))
* **people:** add teams with searchable multi-assign and badge removal ([b93fedc](https://github.com/www-zaq-ai/zaq/commit/b93fedcc26e32e57c32a7406a3808f0f7655f5ef))
* **people:** identity resolution, team management, merge with team union, and e2e coverage ([eb20582](https://github.com/www-zaq-ai/zaq/commit/eb2058208f0ea46138e36709bc756ec7d4f8064e))
* **people:** port People CRUD from license_manager into zaq OSS ([cbe0fc9](https://github.com/www-zaq-ai/zaq/commit/cbe0fc993fc93625cf418e6d56d670781a580400))
* **pipeline:** include retrieved chunks in :after_pipeline_complete hook payload ([82691e1](https://github.com/www-zaq-ai/zaq/commit/82691e129e87433d5b9ec2d318de67863ad3f2b5))
* **rbac:** Person/Team Document Permissions ([26a2df6](https://github.com/www-zaq-ai/zaq/commit/26a2df6137580d4d751a25db25a398d7e0235f29))
* **title_generator:** add Anthropic provider support ([169daf0](https://github.com/www-zaq-ai/zaq/commit/169daf0ae11a54333dc3564d05972607eafe4072))


### Bug Fixes

* **agent:** normalize LLM chain errors across shared runner ([5e74904](https://github.com/www-zaq-ai/zaq/commit/5e74904ce2b8fc18dc20b31601cfd272ec0be12b))
* **channels:** safe map access for is_dm and add open_dm_channel to identity plug stubs ([6e08ee9](https://github.com/www-zaq-ai/zaq/commit/6e08ee9b9a137a62b1915bf57afb6eaf665bc9e8))
* **channels:** scope nostrum to dev/prod, drop adapter compat shim, and fix Credo nesting in register_handlers ([d571e33](https://github.com/www-zaq-ai/zaq/commit/d571e33976f47cbb6566e485bdd0814e00642152))
* **chat:** use requestSubmit() for form submission ([8566380](https://github.com/www-zaq-ai/zaq/commit/8566380be45004e81720593b44b2af9b41bc640d))
* **confidence:** graceful degradation if logprobs are not returned ([91caf25](https://github.com/www-zaq-ai/zaq/commit/91caf253a6ed3141b495a1f76459166d0639d898))
* credo and code review fixes for race, docs and memory leaks ([782804a](https://github.com/www-zaq-ai/zaq/commit/782804a2f9266447659da22620916d2d3409c66e))
* **credo:** resolve all ex_slop strict credo issues — rescue swallowing, identity cases, [@doc](https://github.com/doc) false on public fns, narrator docs, and obvious comments ([773ee4b](https://github.com/www-zaq-ai/zaq/commit/773ee4bacdeb104a4ec01df481fd24f885f5c90f))
* **discord:** wire Discord bridge — fix module loading, integer IDs, mention detection, and Nostrum test isolation ([0ae7a1d](https://github.com/www-zaq-ai/zaq/commit/0ae7a1d42d4a0397caeb948d4d3ab5a5663ce110))
* **docs:** resolve mix docs warnings for hidden modules, undefined refs, and missing Point.t() type ([bd56578](https://github.com/www-zaq-ai/zaq/commit/bd5657866cdce99c97bc197def17a72a395e7ce0))
* **document_chunker:** enforce token limits with title overhead, fix deep bold/italic/bold-numbered heading regex, ([9092b5a](https://github.com/www-zaq-ai/zaq/commit/9092b5ae327da60ee0f33d638dbf84dd8d1b144a))
* **e2e:** e2e tests adapted to new token based styles ([5fb79e0](https://github.com/www-zaq-ai/zaq/commit/5fb79e0dbcfc98e28cfee5072c18b9fe51eb1fa1))
* **e2e:** isolate build artifacts for E2E compile config ([f8dcf49](https://github.com/www-zaq-ai/zaq/commit/f8dcf4952efc8626aea52c5f9766cc5a6194dcb5))
* **email:** Incoming to Pipeline to Outgoing flow as proper reply in mailclient with live config refresh ([8dba950](https://github.com/www-zaq-ai/zaq/commit/8dba95049599a8d149892613f0da3e5858deefe5))
* **encprytion:** enforce a unique code path to handle strict encryption with clean UI errors ([b473ce4](https://github.com/www-zaq-ai/zaq/commit/b473ce476e67ace7312df80ff683166772241058))
* **ingestion, docs:** migration for ingest chunk jobs, moduledoc to new ingest chunk worker ([9461bbf](https://github.com/www-zaq-ai/zaq/commit/9461bbfc58e4fe9e2645a37ed6f00bcaf0cdc819))
* **ingestion, retrieval:** hybrid search limit, better error handling and additional tests ([4a58592](https://github.com/www-zaq-ai/zaq/commit/4a58592e072bf293116c739a0c8e8730ef218bd0))
* **ingestion,ui:** use source prefix conditions for folder visibility and add dismiss buttons, image icon, and ([44556bc](https://github.com/www-zaq-ai/zaq/commit/44556bccda9bd1fc3f0616b1035273189f61eac5))
* **ingestion:** dedicated queue for chunks embedding and ingestion ([5ac68f1](https://github.com/www-zaq-ai/zaq/commit/5ac68f15ba0a0cf677ca9c7cd6eb9712b993103c))
* **ingestion:** document processor compatible with atom and string keys ([05071ec](https://github.com/www-zaq-ai/zaq/commit/05071ec1cdb7a5716a13c48b45162b89b57f30a0))
* **ingestion:** fix visibility on smaller laptop screen size ([918ad0d](https://github.com/www-zaq-ai/zaq/commit/918ad0d97e2f8b9b2a6d02bf139331f3551765bd))
* **ingestion:** keep inline ingestion synchronous ([4e09669](https://github.com/www-zaq-ai/zaq/commit/4e0966965097114b1ab1270bfbb72a0fa6923fe3))
* **ingestion:** resolve multiple file bugs — sidecar visibility, jpeg support, upload errors/removal, accented ([e0d7f81](https://github.com/www-zaq-ai/zaq/commit/e0d7f816417843d517fc0743ac43b6ffa9da805f))
* **jido_chat:** zaq check the dm channel and set it up correctly in the person channel field ([051da6d](https://github.com/www-zaq-ai/zaq/commit/051da6de593b95c5c33ab70546f30b3663ddb16a))
* **notifications:** switch email delivery platform to email:smtp ([04c78a9](https://github.com/www-zaq-ai/zaq/commit/04c78a92156d0345ea1de8ed56bb029722db26cc))
* **people:** add people and add channel forms fixed ([f218f75](https://github.com/www-zaq-ai/zaq/commit/f218f7554c710a71f646cf3f3a93bb02e87a46ad))
* **people:** canonicalize email:imap platform and auto-link email channel on person find-or-create ([fd34818](https://github.com/www-zaq-ai/zaq/commit/fd348188ddfcb511cbe746e67cb67aa8ba3488d1))
* **people:** centralize email channel auto-linking and prefer real names over email-seeded ones ([e208f2e](https://github.com/www-zaq-ai/zaq/commit/e208f2ec61085ee6d604737e67fcfff9093c9424))
* **people:** resolve email:imap sender to existing person via email normalizer and resolve mix ex_dna ([b6c2773](https://github.com/www-zaq-ai/zaq/commit/b6c2773898b51c984546d0e3ca18f5804df7e6c6))
* **prompt:** replace the answering_prompt to support permission ([77f092c](https://github.com/www-zaq-ai/zaq/commit/77f092c82ad44fff132557c551bd9e7b183bee40))
* **rbac:** persist folder permissions, add person document list, fix credo/ex_dna/test warnings ([6642222](https://github.com/www-zaq-ai/zaq/commit/66422227d1749480046b921386a25063a1ce9b29))
* **retrieval:** properly handle errors when unexpected response is returned by an LLM provider ([4e8958e](https://github.com/www-zaq-ai/zaq/commit/4e8958e8f52cd064e211e2175886d7770e59074d))
* **security:** properly wire up missing encryption key errors into system config forms ([e12bb2d](https://github.com/www-zaq-ai/zaq/commit/e12bb2da438df1ca54956f4f549afc9fa56f24a9))
* **system_config:** resolve provider path using selected model id instead of first active model ([6aaa938](https://github.com/www-zaq-ai/zaq/commit/6aaa938793fb1b53e5eb00c641354ef0556454b0))
* **system_config:** restore searchable model dropdown on LLM config form ([93b586d](https://github.com/www-zaq-ai/zaq/commit/93b586dbead6a02454c8a68b486d2504efe0fcc8))
* tests on notification imap live, docs for insecure email html content, db checks on save only ([eb72465](https://github.com/www-zaq-ai/zaq/commit/eb72465305649224b74ef58d61bb2de78a4b746b))
* **ui:** display correct values in validation error messages ([9f9fc0a](https://github.com/www-zaq-ai/zaq/commit/9f9fc0a658f6009dd8b35c08f3a06ba1e3dca874))
* **ui:** update global font to Roboto ([bf3e747](https://github.com/www-zaq-ai/zaq/commit/bf3e7477725d234794a76e27795643e9c8067848))


### Performance Improvements

* **bo-accounts:** use aggregate user and role counts ([ccf60b7](https://github.com/www-zaq-ai/zaq/commit/ccf60b7332c7dcee923b757618d0f4164fefba32))
* **bo-ingestion:** merge job updates incrementally ([428e119](https://github.com/www-zaq-ai/zaq/commit/428e119d886b15ed1f79bb6164ee825017141c5e))
* **frontend:** tighten hook scheduling and remove inline hover js ([46f3a2e](https://github.com/www-zaq-ai/zaq/commit/46f3a2e93948d64fa14f43d21ab03e63fa0322a1))
* **ingestion:** optimize chunk storage and hybrid search limits ([571555c](https://github.com/www-zaq-ai/zaq/commit/571555c5b29415636792bc882c038bd84909a571))

## [0.6.4](https://github.com/www-zaq-ai/zaq/compare/v0.6.3...v0.6.4) (2026-03-28)


### Bug Fixes

* auto open url when app is running, add script in dockerignore ([cc34a1a](https://github.com/www-zaq-ai/zaq/commit/cc34a1a7828d58fd3baa5608e8b89cbb3aead8ae))

## [0.6.3](https://github.com/www-zaq-ai/zaq/compare/v0.6.2...v0.6.3) (2026-03-27)


### Bug Fixes

* **docker:** build docker image for arm64 platform too ([529a1e2](https://github.com/www-zaq-ai/zaq/commit/529a1e2bfaa800c10752cc0f52594d8b27db3417))

## [0.6.2](https://github.com/www-zaq-ai/zaq/compare/v0.6.1...v0.6.2) (2026-03-27)


### Bug Fixes

* **agent:** tolerate incomplete LLM responses (stop_reason: length) ([117e286](https://github.com/www-zaq-ai/zaq/commit/117e2868e5948a922d2586ce96ec14042a27efdb))
* **ci/cd:** stop double trigger of gitleaks action ([2411778](https://github.com/www-zaq-ai/zaq/commit/2411778e6f6c239cbb3f0f27369ab7468b6f5a89))
* **CI:** split steps into jobs ([f27d8ae](https://github.com/www-zaq-ai/zaq/commit/f27d8aeb749342111d6065ed288e375b7934a82b))
* **e2e:** seed telemetry rollups and add benchmark support to gauge and radar ([2be531e](https://github.com/www-zaq-ai/zaq/commit/2be531ee72841897db2041b7e24fd20751c47985))
* **llm:** fix issue [#166](https://github.com/www-zaq-ai/zaq/issues/166) ([cd4dd23](https://github.com/www-zaq-ai/zaq/commit/cd4dd233c878fd9c5fee387a2d5a64310e0cf607))
* **system:** create a ui llm, embedding, image to text and ingestion configuration ([a37e145](https://github.com/www-zaq-ai/zaq/commit/a37e145e02272bc02d0a9bac1b6da9ddf9deb631))
* **ui:** adjust display when sidebard is collapsed ([9bc5798](https://github.com/www-zaq-ai/zaq/commit/9bc57980c8ab5f4323c478c575650f0c25e33e76))
* **ui:** move user action under header profile and add Github card ([2a47683](https://github.com/www-zaq-ai/zaq/commit/2a47683f71df18b716a0bcca434911d0ad1909ae))
* **unlock:** create unlock and lock feature on the embedding ([5c2f4ff](https://github.com/www-zaq-ai/zaq/commit/5c2f4ff16cf7624a0cfe80e938bf52c497022e2a))

## [0.6.1](https://github.com/www-zaq-ai/zaq/compare/v0.6.0...v0.6.1) (2026-03-25)


### Features

* **sharing:** add public shared conversation view with copy-link UI ([#161](https://github.com/www-zaq-ai/zaq/issues/161)) ([cc29151](https://github.com/www-zaq-ai/zaq/commit/cc29151d7dd344e143fd96585427ac0462790de7))


### Bug Fixes

* **agent:** pipeline ([e4b4487](https://github.com/www-zaq-ai/zaq/commit/e4b448759ea67dce525c214ad89fc87070d17f66))
* **docker:** Expose the env for sensitive config encryption ([dd38e64](https://github.com/www-zaq-ai/zaq/commit/dd38e646ee1b67bae82b9a0d2c5832e68a8d9dab))
* **history:** extract shared History module and centralize key format ([9066f2a](https://github.com/www-zaq-ai/zaq/commit/9066f2a8a2d12796f8dff5dc793427efac6358a3))
* **ingestion:** preview on docker by providing sane defaults and updating docs ([6e7a29a](https://github.com/www-zaq-ai/zaq/commit/6e7a29a8c4d5ac7a5d2a87c357d02512fd72686a))
* **license:** load public key from .zaq-license package ([0120e67](https://github.com/www-zaq-ai/zaq/commit/0120e6744199574f05858502db7def1de995897d))
* **sharing:** correct commit type for shared conversation view ([04261ca](https://github.com/www-zaq-ai/zaq/commit/04261ca6f00bd71ddb935ce05bcb1e05bdaf18e0))
* **sidebar:** refresh locked menu items on license activation ([#159](https://github.com/www-zaq-ai/zaq/issues/159)) ([185c56c](https://github.com/www-zaq-ai/zaq/commit/185c56c1a4d500547fa0145b7787064d0cb99b4d))
* **telemetry:** 90D time range display based on actual Weeks. Simplify weighted average computation on time-series ([32f2f80](https://github.com/www-zaq-ai/zaq/commit/32f2f808f72115e72ded76f94cbe7ce7388caa6c))
* **telemetry:** code format ([434c6f0](https://github.com/www-zaq-ai/zaq/commit/434c6f098548e5abc45b3dbe0199f05fc9014edc))
* **telemetry:** consume weights for no-answer rate weighted average display ([9b47e37](https://github.com/www-zaq-ai/zaq/commit/9b47e37b9f4c4786766c9de46ce9b361f0a36bd3))

## [0.6.0](https://github.com/www-zaq-ai/zaq/compare/v0.5.0...v0.6.0) (2026-03-23)


### Features

* **accounts,engine:** add email field, notification center, and forgot-password flow ([fd347c3](https://github.com/www-zaq-ai/zaq/commit/fd347c3b835c9bb9c8febd34b866e2d0824a2a37))
* **bo:** create a knowledge gap page ([b8d52bd](https://github.com/www-zaq-ai/zaq/commit/b8d52bd14d1db6701a28aa1cf5cd9fbf68ba7c99))
* **channels:** add notifications channel with email/smtp configuration UI ([3075471](https://github.com/www-zaq-ai/zaq/commit/30754717aab6ce6fd03b449118bab2b9ac43cd00))
* **engine:** add Router for adapter-agnostic question dispatch ([df3a30b](https://github.com/www-zaq-ai/zaq/commit/df3a30b90cd18046b1d7f39805f856aa4a0c4fcf))
* **engine:** fix SME reply routing and stale question expiry handling ([9eecd3e](https://github.com/www-zaq-ai/zaq/commit/9eecd3e4170e2c1ddde3c5499f38aa9c12d89142))
* **hooks:** add generic hook system with sync/async dispatch and wire into Agent.Pipeline ([e863fc6](https://github.com/www-zaq-ai/zaq/commit/e863fc67bed204596acbf9aeff5a2cc6a91ea804))
* **hooks:** dispatch :feedback_provided hook with conversation history after message rating ([edc5eeb](https://github.com/www-zaq-ai/zaq/commit/edc5eeb998713abb8083e481d88d81acb32a7d31))
* **ingestion:** add Excel and Word document support with file grouping ([59eeffe](https://github.com/www-zaq-ai/zaq/commit/59eeffe94e92aa54d1f33f4596c2a166316bf03e)), closes [#77](https://github.com/www-zaq-ai/zaq/issues/77)
* **ingestion:** add PDF → markdown pipeline via Python scripts ([1a58ab4](https://github.com/www-zaq-ai/zaq/commit/1a58ab44b5679c1cfcb8439d75dc6e25418466b4))
* **ingestion:** persist image sidecars with metadata links ([7558ad5](https://github.com/www-zaq-ai/zaq/commit/7558ad5a0982524ae962cf6e7bff610222045baf))
* **ingestion:** role-based file access control with public sharing ([#97](https://github.com/www-zaq-ai/zaq/issues/97)) ([7508541](https://github.com/www-zaq-ai/zaq/commit/750854192fbbee9185d7c34bd2c51dd1cfc35ced))
* **ingestion:** support PNG/JPG ingestion and harden PDF pipeline path handling ([a226e62](https://github.com/www-zaq-ai/zaq/commit/a226e62ceadba7dddf073881aa6df505033a4717))
* **license:** add upload UI and replace file watcher with startup loader ([86c7e7a](https://github.com/www-zaq-ai/zaq/commit/86c7e7a94ff7d71709f01877d1b9b63219c5a7b6))
* **license:** fix feature key matching and enhance licensed features display ([009e2fd](https://github.com/www-zaq-ai/zaq/commit/009e2fd48d2872c5aa68b2397dc811a3befcb549))
* **license:** hook-based question dispatch and license lifecycle fixes ([fc6774a](https://github.com/www-zaq-ai/zaq/commit/fc6774acf3cdbfc1b42a40762d1f8744f7fa72be))
* **license:** provision Oban queues and crontab at runtime from licensed feature modules ([af70194](https://github.com/www-zaq-ai/zaq/commit/af70194dcf911d624e2482f0dce6c725aa49d406))
* **notifications:** implement notification center phases 1–5 and 7 ([67217cd](https://github.com/www-zaq-ai/zaq/commit/67217cd1bbd40c90596c7b9a64aaeac5875e5bcf))
* **notifications:** implement notification center with email/mattermost routing, delivery logs UI, and recipient filter ([90d680f](https://github.com/www-zaq-ai/zaq/commit/90d680ff71b1cd4f93c95bdcc8273dd6319ceae7))
* **notifications:** route welcome/reset emails through notification center and move delivery logs into channels ([3b9cdb4](https://github.com/www-zaq-ai/zaq/commit/3b9cdb4a41e046bcc50ea1cf14f4896ec5c34514))
* **oban:** move Oban to root supervisor and wire knowledge gap workers ([840ed3a](https://github.com/www-zaq-ai/zaq/commit/840ed3ad4e19fd55ba6bd40a6d375847104ae0ba))
* **oban:** replace Cron plugin restart with DynamicCron plugin supporting runtime schedule injection ([8f71636](https://github.com/www-zaq-ai/zaq/commit/8f716369c826147c70480ed825777c0ee41632e0))
* **retrieval:** centralize retrieval process ([d3f724b](https://github.com/www-zaq-ai/zaq/commit/d3f724bfeab944abbd553d983e8d524b78b2a7f2))
* **system:** add email config UI, welcome email, and password show toggle ([1ac7a0a](https://github.com/www-zaq-ai/zaq/commit/1ac7a0ac287ecf6f851906b6e049983040c87274))
* **telemetry:** add dashboard for knowledge base metrics ([b0fced4](https://github.com/www-zaq-ai/zaq/commit/b0fced466175ec777992c2f078984a8a4985a242))
* **telemetry:** canonical contract for chart producer &lt;-&gt; consumer based on hybrid struct payload implemented on metric card ([50cbae9](https://github.com/www-zaq-ai/zaq/commit/50cbae9f9b32ee9d0356330bbe75f9edae1d4c76))
* **telemetry:** collect data with specific telemetry pipeline, central data fetcher and preparation for telemetry sync in benchmark mode ([9e12a96](https://github.com/www-zaq-ai/zaq/commit/9e12a968ec2e8a95d682a98316ed06e3dd7e3b20))
* **telemetry:** enforce contract on all chart types ([3bec21f](https://github.com/www-zaq-ai/zaq/commit/3bec21fcb2d5d83e8a3ca274fe19ec858ccc22fa))
* **telemetry:** introduce struct for unified answers accross channels, wire up answer metrics into telemetry ([9bc656a](https://github.com/www-zaq-ai/zaq/commit/9bc656a4ff4a331e8a1794f96b4a670b3421c66e))
* **telemetry:** produce graph component and wire dummy data to evaluate dashboards ([f414474](https://github.com/www-zaq-ai/zaq/commit/f41447418550f1db610df407db615a8cb66763b7))
* **telemetry:** produce the LLM Performance dashboard and connect to main dashboard page ([306af61](https://github.com/www-zaq-ai/zaq/commit/306af61e14894951afdd8a71cf38aa5b387ac3c4))
* **telemetry:** wire up benchmark data as datasource and into charts ([c76125d](https://github.com/www-zaq-ai/zaq/commit/c76125d1854282235852c97753d301c975b03856))
* **telemetry:** wire up LLM calls ([d2a2d5b](https://github.com/www-zaq-ai/zaq/commit/d2a2d5bbb9f7ba0d4d89c42117b3133ce99e5350))
* **user:** enable a user profile page and add password change ability for own user ([9981606](https://github.com/www-zaq-ai/zaq/commit/9981606cbdeb171ab09aa024376aa4679e84d98e))


### Bug Fixes

* **bo:** Replace playground by chat ([0daeb11](https://github.com/www-zaq-ai/zaq/commit/0daeb115ca37ab6e93efdf1f67efdf9d57648bad))
* **db:** register Zaq.PostgrexTypes in production Repo config ([ec5efb6](https://github.com/www-zaq-ai/zaq/commit/ec5efb687fdf0f94491816fc654355358239c29d))
* **docker:** fix docker image ([6ca46e1](https://github.com/www-zaq-ai/zaq/commit/6ca46e1f95cdd9466176415218adfa9aa0f2fb92))
* **docker:** support python3 ([9fcbeb5](https://github.com/www-zaq-ai/zaq/commit/9fcbeb559477abbd3c04931390021ddbcb1e95b2))
* **email:** smtp configuration with enforced security, gmail smtp fix and centralized error message wiring ([0f7c0fb](https://github.com/www-zaq-ai/zaq/commit/0f7c0fbbf78d9d81c20505217f5dd8b7c314a730))
* **gitleaks:** avoid gitleaks check on dummy key in test env ([7a24e8d](https://github.com/www-zaq-ai/zaq/commit/7a24e8db51ee19a129533ec0aff7ce5e9b982e9d))
* **ingestion:** fix file preview, volume-prefixed sources, and real-time status badges ([5ae7eea](https://github.com/www-zaq-ai/zaq/commit/5ae7eea4c4ee58352951e6f0400891e6129b3e29))
* **ingestion:** fix file preview, volume-prefixed sources, and real-time status badges ([e24527e](https://github.com/www-zaq-ai/zaq/commit/e24527e7a14b73852dfb0fe13089bc3a6c898ef0))
* **ingestion:** keep sidecars aligned on delete, move, and rename ([6f9adf8](https://github.com/www-zaq-ai/zaq/commit/6f9adf8ec86d4787229a693ca580c02c1e4838bf)), closes [#119](https://github.com/www-zaq-ai/zaq/issues/119)
* **ingestion:** resolve paths against volume root, not hardcoded base_path ([#103](https://github.com/www-zaq-ai/zaq/issues/103), [#96](https://github.com/www-zaq-ai/zaq/issues/96)) ([30bc3bf](https://github.com/www-zaq-ai/zaq/commit/30bc3bfd60f6fd8c51648bc275c46720c1ac929a))
* **ingestion:** support spaces in file names and support jpg and png images ([9a9472f](https://github.com/www-zaq-ai/zaq/commit/9a9472fdffb4c2bb2711152f1cfb9c4f6e77ad14))
* **license:** move expiry logic to encrypted paid module and improve time-left display ([27bdafb](https://github.com/www-zaq-ai/zaq/commit/27bdafb8e91436684518c75c3efb9159d6a844e9))
* **license:** removed the file watcher, license should now be uploaded through a form in the BO ([0c3c500](https://github.com/www-zaq-ai/zaq/commit/0c3c50047afb691c84d8892f3b7b9d877b1e3aa2))
* **notifications:** address PR review — safe adapter resolution, atomic status transitions, channel validation, and consistent return types ([262ee49](https://github.com/www-zaq-ai/zaq/commit/262ee4982ade9c5a69f0cc391e9e75e074aa5f03))
* **preview:** resolve volume-prefixed paths in file preview/serving ([7274566](https://github.com/www-zaq-ai/zaq/commit/727456658e6a90774043b2f5d71b5945a908dfa7))
* **telemetry:** adjust labels and data association for 24h and 30D scales ([fdd666f](https://github.com/www-zaq-ai/zaq/commit/fdd666f6ab41e529ce730dfbfa4ea6244c982bd9))
* **telemetry:** code review comments ([94dd275](https://github.com/www-zaq-ai/zaq/commit/94dd2756564ddc69c4d26709edeb5acf15f7bab0))
* **telemetry:** credo and proper merge of new pipeline module ([f0075fb](https://github.com/www-zaq-ai/zaq/commit/f0075fbfa7aae10b58626a6bc7706cc3e9454729))
* **telemetry:** minor bugs in benchmark, baseline and secondary time series chart. Gauge zero value fix ([90430dc](https://github.com/www-zaq-ai/zaq/commit/90430dc7f20420314fe82f40e15969ff449bfa26))
* **telemetry:** properly integrate system settings form ([417a104](https://github.com/www-zaq-ai/zaq/commit/417a104c6fe33f0ba97884c26e4d7ddfef5fa94b))
* **telemetry:** wire x-axis labels in the time-series chart ([b915bc9](https://github.com/www-zaq-ai/zaq/commit/b915bc94d227f82d67b828e8b41419b87ab9e046))
* **tests:** buffer flush ([9f5d283](https://github.com/www-zaq-ai/zaq/commit/9f5d283834bd989d88fb2ae3dad6395c61c01e67))

## [0.5.0](https://github.com/www-zaq-ai/zaq/compare/v0.4.0...v0.5.0) (2026-03-16)


### Features

* **gitflow:** fix git actions to support gitflow ([0bf2929](https://github.com/www-zaq-ai/zaq/commit/0bf292922b5cf1be15c6bcd14bc0b9d8e5215732))
* **gitflow:** fix git actions to support gitflow ([1c3ad62](https://github.com/www-zaq-ai/zaq/commit/1c3ad62a773b4f5b028e6b997f47e30c0309beaa))

## [0.4.0](https://github.com/www-zaq-ai/zaq/compare/v0.3.0...v0.4.0) (2026-03-16)


### Features

* **engine:** conversation management ([#87](https://github.com/www-zaq-ai/zaq/issues/87)) ([84d3ebd](https://github.com/www-zaq-ai/zaq/commit/84d3ebda8423b9f6f385c538af8823a29526b5ce))
* implement RBAC engine — role-scoped ingestion and retrieval ([#86](https://github.com/www-zaq-ai/zaq/issues/86)) ([71fbbba](https://github.com/www-zaq-ai/zaq/commit/71fbbba958ac1b228295ad7234b96b46d092de94))

## [0.3.0](https://github.com/www-zaq-ai/zaq/compare/v0.2.0...v0.3.0) (2026-03-13)


### Features

* add multi-volume ingestion support ([#66](https://github.com/www-zaq-ai/zaq/issues/66)) ([3c7813f](https://github.com/www-zaq-ai/zaq/commit/3c7813f5616a7d5ec78f5b6b50645fd8303e9b85))
* Dev to main ([#49](https://github.com/www-zaq-ai/zaq/issues/49)) ([57188d6](https://github.com/www-zaq-ai/zaq/commit/57188d6135f3afae9db9e08486d34d1c561dd086))
* Dev to main ([#49](https://github.com/www-zaq-ai/zaq/issues/49)) ([#52](https://github.com/www-zaq-ai/zaq/issues/52)) ([5ab655c](https://github.com/www-zaq-ai/zaq/commit/5ab655c01d160611a8632917444cf8b2ae94ec49))
* increase password security requirements [#3](https://github.com/www-zaq-ai/zaq/issues/3) ([#11](https://github.com/www-zaq-ai/zaq/issues/11)) ([76836e8](https://github.com/www-zaq-ai/zaq/commit/76836e874ffb390a3169fddc729d6af3ad5cb29f))
* **ingestion:** local memory channel ([#28](https://github.com/www-zaq-ai/zaq/issues/28)) ([96ca943](https://github.com/www-zaq-ai/zaq/commit/96ca943217f3890864dbb83c5f7cb7fb7a2fbced))
* **ingestion:** local memory channel ([#28](https://github.com/www-zaq-ai/zaq/issues/28)) ([7e949cc](https://github.com/www-zaq-ai/zaq/commit/7e949ccf3538ee1d7a02717bedbc8f1fff827899))
* **rules:** Added Gitflow workflow with semantic versioning to AGENTS.md ([#44](https://github.com/www-zaq-ai/zaq/issues/44)) ([c431cf3](https://github.com/www-zaq-ai/zaq/commit/c431cf354a57ca6a2013753992b157378ae3d780))
* setup oc assistant in issue and PR comments for maintainers only ([#31](https://github.com/www-zaq-ai/zaq/issues/31)) ([b391708](https://github.com/www-zaq-ai/zaq/commit/b391708e441ea0c4ff3e9a6dc6cc413f4639ce03))


### Bug Fixes

* **agents:** enforce using serena ([#82](https://github.com/www-zaq-ai/zaq/issues/82)) ([c34df19](https://github.com/www-zaq-ai/zaq/commit/c34df1995aae1de9a2cac40e47c3cd84c4df3e95))
* mismatch coding style ([#74](https://github.com/www-zaq-ai/zaq/issues/74)) ([7074856](https://github.com/www-zaq-ai/zaq/commit/70748561b2c0d3f2220605e42bc35cd5314f2a26))
* **opencode:** Opencode setup ([#34](https://github.com/www-zaq-ai/zaq/issues/34)) ([6f85c6f](https://github.com/www-zaq-ai/zaq/commit/6f85c6f354da8e106fa95b1ab7f5a0d5a4a0bd91))
* **password requirements:** Added password validation feedback to user form. ([#40](https://github.com/www-zaq-ai/zaq/issues/40)) ([8433aba](https://github.com/www-zaq-ai/zaq/commit/8433abacfcbba8bef9354d7ad44ef4ea604185a4))
* workflow ([#68](https://github.com/www-zaq-ai/zaq/issues/68)) ([88a867d](https://github.com/www-zaq-ai/zaq/commit/88a867dc3d76e08a7cfa45ffd26383618529d0b9))

## [0.2.0](https://github.com/www-zaq-ai/zaq/compare/v0.1.0...v0.2.0) (2026-03-11)


### Features

* add authentication system for backoffice ([133f0c3](https://github.com/www-zaq-ai/zaq/commit/133f0c379775bc5a0afa4e07d5c4cc30e4108173))
* add chat playground with RAG agent pipeline ([3e85317](https://github.com/www-zaq-ai/zaq/commit/3e8531731489c5baca34ed410f2188833962f9c4))
* **agent & ingestion:** add supervisors and API controller (tasks 4.2, 4.3) ([f85640b](https://github.com/www-zaq-ai/zaq/commit/f85640b883773f45e1811eb57ea4facc866dd12c))
* **agent & ingestion:** migrate Agent & Ingestion foundation from zaq_agent ([8629289](https://github.com/www-zaq-ai/zaq/commit/86292896d4f9f5751dcd44b3a420aa9325625532))
* auto-discover peer nodes via EPMD, broadcast events through PubSub ([5900063](https://github.com/www-zaq-ai/zaq/commit/5900063bf2dd910d16aaf8029f556d23709178ca))
* **bo & ingestion:** add file management UI with modals and grid view ([6d9f58d](https://github.com/www-zaq-ai/zaq/commit/6d9f58d791039442c4afb3aff5373b97045a4e46))
* **bo:** add full CRUD ontology LiveView with visual tree ([e584b99](https://github.com/www-zaq-ai/zaq/commit/e584b99adc31a2771fc9ee7f9b70528ed370df7c))
* **bo:** add layout, user/role CRUD, and auth improvements ([6884803](https://github.com/www-zaq-ai/zaq/commit/6884803ba36d0d85621af92b5b377ae5620468f2))
* **bo:** add license page and revamp dashboard ([7cfc793](https://github.com/www-zaq-ai/zaq/commit/7cfc7938db9399955e6c643bce2329a28d6c12cd))
* **channels:** add provider index page and enriched Mattermost detail view ([0af42de](https://github.com/www-zaq-ai/zaq/commit/0af42de2c00fd092e6591974e9f2c9f7ea5cfbe9))
* **ci:** Add dev branch ([#13](https://github.com/www-zaq-ai/zaq/issues/13)) ([7f008d5](https://github.com/www-zaq-ai/zaq/commit/7f008d5ce5eebada1a3c73c762bd28c1490ef66e))
* **ci:** Install inotify-tools for `file_system` deps ([d897a9d](https://github.com/www-zaq-ai/zaq/commit/d897a9dd8be3fa88fb0a6f2cf120ba0b3a5f47a5))
* complete Phase 2 migration and add AI BO pages ([a1a9917](https://github.com/www-zaq-ai/zaq/commit/a1a991726af97fc4ada6ff285b7bf4845a37485d))
* **engine:** introduce Engine orchestrator with ingestion/retrieval channel architecture ([373bb5b](https://github.com/www-zaq-ai/zaq/commit/373bb5b1e183597e5781ea267d734be4b753083c))
* **ingest & bo:** Add BO Ingestion Management page ([c0d5fd8](https://github.com/www-zaq-ai/zaq/commit/c0d5fd8271f5dcb88fcb5c19799487eeb776cee7))
* **license:** add file system watcher for automatic license detection ([83fca99](https://github.com/www-zaq-ai/zaq/commit/83fca9966597f4e78a220e6a267e2a4fefd53d59))
* **license:** add license verification and BEAM module loader ([7429238](https://github.com/www-zaq-ai/zaq/commit/7429238f9c6c69ffa9a29ce5ffeb88d3b3e7ce69))
* **license:** integrate license_manager and ontology post-load pipeline ([741f2ea](https://github.com/www-zaq-ai/zaq/commit/741f2ea88f9d410eda1fe1c9e8f90a30f57d77b3))
* Mattermost retrieval channel picker + RAG pipeline integration ([37c38a4](https://github.com/www-zaq-ai/zaq/commit/37c38a46d811d1ee9e2b91e89ef0923eed97d72d))
* migrate DocumentChunker and DocumentProcessor (tasks 3.1, 3.2) ([a20d493](https://github.com/www-zaq-ai/zaq/commit/a20d493891d5772c80d316bc41720b27851159ed))
* multi-node distributed deployment + service availability gating ([11e6f4a](https://github.com/www-zaq-ai/zaq/commit/11e6f4a0932e8f3656e27e850d90dbbc56b89bb9))
* **playground:** UI/UX overhaul - redesign chat interface ([eaa6caf](https://github.com/www-zaq-ai/zaq/commit/eaa6caf2ace576d93deaa33b08df59453038ef07))


### Bug Fixes

* **ci:** use pgvector/pgvector image to fix missing vector extension ([d2dd650](https://github.com/www-zaq-ai/zaq/commit/d2dd6508894898765e0e228d496436eb8cfc5ad6))
* correct redirection logic when password change is required (on first login) ([a74cd9a](https://github.com/www-zaq-ai/zaq/commit/a74cd9aaa39f9ac27afe2d436538892945920b07))
* credo and wire credo inside precommit command ([20b5da8](https://github.com/www-zaq-ai/zaq/commit/20b5da8010ebf0932c21654cd82e0a8a6ff9c158))
* embedding storage, job retry loop, and ingestion lifecycle ([73f9cd3](https://github.com/www-zaq-ai/zaq/commit/73f9cd3a3f9bf3bd9e550c102038ccbdbe0b828e))
* **ingestion:** fix test suite for worker path resolution and mock contracts ([d65e110](https://github.com/www-zaq-ai/zaq/commit/d65e110f77a2a8bb86a8b77a466a11ea2ef11990))
* resolve credo nesting warnings, format and add CI pipeline ([6a00eb4](https://github.com/www-zaq-ai/zaq/commit/6a00eb441ee236691cdb7412a3500b70e759d372))

## Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
