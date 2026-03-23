# Changelog

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
