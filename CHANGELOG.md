# Changelog

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
