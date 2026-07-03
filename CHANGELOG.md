# Changelog

## [0.14.0](https://github.com/www-zaq-ai/zaq/compare/v0.13.0...v0.14.0) (2026-07-03)


### ⚠ BREAKING CHANGES

* **workflows:** make map an internal-only node type, author iteration via Batch

### Features

* add ZaqWeb.Select component with zaq-control-select styling ([efebe54](https://github.com/www-zaq-ai/zaq/commit/efebe54a9bde3801283fa35384c2a5d3b9b90708))
* **agent:** add single-cell sheet updates and integer-coercing increment tool ([96426d2](https://github.com/www-zaq-ai/zaq/commit/96426d2bfca2f805c07fff6115867663f8a2273d))
* **agent:** add workflow, people, accounts, and sheets tools with engine edge routing ([c499835](https://github.com/www-zaq-ai/zaq/commit/c499835fbb0d55cc34bd928d5e82ed87ba12c876))
* **agent:** isolate run_agent per workflow run/step and forward actor ([d07af39](https://github.com/www-zaq-ai/zaq/commit/d07af39e8677323109a29ff199bee9e0d65da997))
* **agent:** make dispatch_event a usable tool with optional input, destination, and cascade forwarding ([aea8d8b](https://github.com/www-zaq-ai/zaq/commit/aea8d8bc1ee4e1755d30e027d33304f23658a0cc))
* **agent:** wire trusted identity into fetch_history conversation recall ([19ce3fa](https://github.com/www-zaq-ai/zaq/commit/19ce3fa5a93833aad793011e45e6fcb564c7a86c))
* **channels, workflow:** enable workflow on communication channel messages ([502b5a8](https://github.com/www-zaq-ai/zaq/commit/502b5a8f47639d4cb064bc56e9852577ae46cd6f))
* **channels:** route incoming messages to agent or simply fire an event with no-op - [channels]: trigger a workflow ([10be048](https://github.com/www-zaq-ai/zaq/commit/10be04826c8420c7e2e86e59563bf238d66866bc)), closes [#503](https://github.com/www-zaq-ai/zaq/issues/503)
* **datasources:** connect data source records to ingestion UI to list docs and navigate - phase 2 of [Ingestion] Generic UI for external Data Sources [#486](https://github.com/www-zaq-ai/zaq/issues/486) ([3bc8ab3](https://github.com/www-zaq-ai/zaq/commit/3bc8ab33c94187c51db14d9a69de7dc08d97a46b))
* **engine:** add batch field detection and scoped node preparation in dag builder ([94ca583](https://github.com/www-zaq-ai/zaq/commit/94ca583e1d150144809f50944145acf4f1dc9374))
* **engine:** add cron trigger scheduling with DynamicCron and worker ([184f7ce](https://github.com/www-zaq-ai/zaq/commit/184f7cee25d8a387d6a71816d172345a158219d2))
* **engine:** add human-in-the-loop approval flow with approve/reject run lifecycle ([d9cb2c5](https://github.com/www-zaq-ai/zaq/commit/d9cb2c5b22350f193cfbba2b999679ba66df1e0c))
* **engine:** add map iteration primitive, migrate Batch onto it, drop Iterate ([2df07c6](https://github.com/www-zaq-ai/zaq/commit/2df07c64cfa36e3690308fa78410a5e43b9754ff))
* **engine:** add trigger management API handler and list_triggers_with_workflows_and_recent_runs ([5efcd0b](https://github.com/www-zaq-ai/zaq/commit/5efcd0bdeeabfcdfaa4360829dded081540b7faf))
* **engine:** add workflow composition primitive and map node type ([336e185](https://github.com/www-zaq-ai/zaq/commit/336e185f9db552e0d52fa93d8487a695edc3ad95))
* **engine:** add workflow node behaviour and in-memory prepared run DAG ([59e8af5](https://github.com/www-zaq-ai/zaq/commit/59e8af54a0a37a7eaec6592c3d8fa53495ac3c89))
* **engine:** cascade action results through workflow edges for cross-step conditions ([1b6345b](https://github.com/www-zaq-ai/zaq/commit/1b6345b7873f18ca81d58919e112c94d0a6ea21d))
* **engine:** dispatch workflow lifecycle events via NodeRouter on run transitions ([07ee112](https://github.com/www-zaq-ai/zaq/commit/07ee1124baf0be01f6e10d9dd304e3450b0fb3bc))
* **engine:** distinguish graceful shutdown from crash on workflow runs ([8404e43](https://github.com/www-zaq-ai/zaq/commit/8404e43cc7f663109acff8f7032598cc1e18acdb))
* **engine:** support optional trigger on workflow import ([c2fb0a7](https://github.com/www-zaq-ai/zaq/commit/c2fb0a758943271008cc672fc88eb653c05b72d1))
* **engine:** validate edge endpoints and connectivity in composition ([6d9a478](https://github.com/www-zaq-ai/zaq/commit/6d9a478330bebd15eebb02de5afb26da1a481eb4))
* **engine:** validate workflows at save and run prepared DAGs ([b2dd8cd](https://github.com/www-zaq-ai/zaq/commit/b2dd8cdd830e737c03a92d0a9dfcb5f0cd7b9120))
* **engine:** workflow engine improvements and Credo complexity fix ([8e953c1](https://github.com/www-zaq-ai/zaq/commit/8e953c144be61bf2a5a6beb0f0a023c3fa0482c4))
* **live:** add triggers BO page with components, routing, and test coverage ([1af895b](https://github.com/www-zaq-ai/zaq/commit/1af895bba1cbeda07759d8a5d87bd989e8395fb8))
* **live:** add virtual start origin node with trigger input card to run view ([29f9d3b](https://github.com/www-zaq-ai/zaq/commit/29f9d3b9cfd9a8508249e303e5eafc437862219a))
* **live:** add workflow BO screens and action result input tracking ([f80fd66](https://github.com/www-zaq-ai/zaq/commit/f80fd66ea4fae5fe60fb426c8190c7985bce28e0))
* replace native select with searchable_select panel (searchable=false) for styled dropdown ([d1e869f](https://github.com/www-zaq-ai/zaq/commit/d1e869fef16fb09c70ab9df291913782f7867b9d))
* **web:** surface agent traces on workflow run step cards ([875472d](https://github.com/www-zaq-ai/zaq/commit/875472d936fe57fe26123d131b6812a82ed73e25))
* **workflow:** add json tree hook and component, per-page selector, and status toggle ([6d838d1](https://github.com/www-zaq-ai/zaq/commit/6d838d111dbe81e5d5c50c14dfcc6fd6a374612e))
* **workflows:** add BO pages for workflow list, detail, and run log trail ([81e88d7](https://github.com/www-zaq-ai/zaq/commit/81e88d78e5c8d76e93e56e25c52fe6fc169d995e))
* **workflows:** add BO workflow pages with DAG visualisation, trigger icons, run/delete actions, and ([cc1e9b3](https://github.com/www-zaq-ai/zaq/commit/cc1e9b34650fe8126c8b9a12560418e7f410774a))
* **workflows:** add cancellation support, structured run lifecycle, and BO run/detail UI improvements ([0c09373](https://github.com/www-zaq-ai/zaq/commit/0c0937325f332bef45fe45f46caf5431a3a13a53))
* **workflows:** add conditional edge routing, action wrapper, and full test coverage ([34b4fe1](https://github.com/www-zaq-ai/zaq/commit/34b4fe153393e621266d7aec114145cb92750c6b))
* **workflows:** add EdgeCondition.changeset/1 and consolidate condition validation ([97a030e](https://github.com/www-zaq-ai/zaq/commit/97a030eebd206d3826b23aa0f22543821ca99df4))
* **workflows:** add HITL dag styling, trigger icon derivation, run-now button, and test coverage ([2d87a9a](https://github.com/www-zaq-ai/zaq/commit/2d87a9a039134b053c2b4ef1d06b4ed5c007baa8))
* **workflows:** edges as conditional data-connector routes with full coverage ([3f4596e](https://github.com/www-zaq-ai/zaq/commit/3f4596e421b283f69c61725d7d395ec71d5a4540))
* **workflows:** make condition halt failures human-readable in run view ([6f4cfa7](https://github.com/www-zaq-ai/zaq/commit/6f4cfa7b5b44918b14704f743d9f8b7f5519b635))
* **workflows:** support jsonc imports and fixes [#513](https://github.com/www-zaq-ai/zaq/issues/513) ([da4e125](https://github.com/www-zaq-ai/zaq/commit/da4e1253275751be94582806f53f461f3188f2db))


### Bug Fixes

* **action:** add metadata when loading history messages ([de01e43](https://github.com/www-zaq-ai/zaq/commit/de01e430bdaaed2d34f4e431f3d8d004635e2821))
* **action:** correctly extracting rows with trailing headers and empty values - fixes [#515](https://github.com/www-zaq-ai/zaq/issues/515) ([70179e0](https://github.com/www-zaq-ai/zaq/commit/70179e02439619aa4e535b9e7ee5ca67df7de928))
* **actions:** add metadata about headers information in extract_rows - fixes [#512](https://github.com/www-zaq-ai/zaq/issues/512) ([681d767](https://github.com/www-zaq-ai/zaq/commit/681d767705985ceedf784a0a7e5c97b151bf4204))
* **actions:** delegate increment action to jido_action catalog ([afe70a2](https://github.com/www-zaq-ai/zaq/commit/afe70a2aaa1ac6deb159b7c8f041dade669b8576))
* **agent:** route RunAgent to executor and authorize machine runs ([42b599a](https://github.com/www-zaq-ai/zaq/commit/42b599a82359507e672018832fd234896ce9141c))
* **agent:** update tool module refs to namespaced paths and sync tests ([2198ee0](https://github.com/www-zaq-ai/zaq/commit/2198ee00b52a41e36ee2ee4547c263339450fbb6))
* **channels:** display errors on BO on gateway failures ([75399f4](https://github.com/www-zaq-ai/zaq/commit/75399f410f079194e6893c4862689ce05edd2840))
* **datasource:** normalize parent_id to jido_connector when creating documents ([7d17e85](https://github.com/www-zaq-ai/zaq/commit/7d17e85f27e6c4c711c476d62f220775fa8ec01c))
* **engine:** auto-recover orphaned workflow runs on driver death ([5f6776d](https://github.com/www-zaq-ai/zaq/commit/5f6776dc61094ef34455083ad08525ed8cb55a64))
* **engine:** capture real reason for orphaned workflow step failures ([3982a91](https://github.com/www-zaq-ai/zaq/commit/3982a917a5a59a564a78f588a599048225b5f102))
* **engine:** make pause_run immediate — kill agent, freeze step_run duration, broadcast updates ([7fac7a8](https://github.com/www-zaq-ai/zaq/commit/7fac7a8feeefc576af3f5700c4aa593d3edb51f6))
* **engine:** make workflow event dispatch and triggering reliable ([e42761a](https://github.com/www-zaq-ai/zaq/commit/e42761a11c6a04615f62dcbfc4b5e9f95ffbdfa1))
* **engine:** register RunRegistry in supervisor and test helper ([6628ca7](https://github.com/www-zaq-ai/zaq/commit/6628ca7d8eb06e3c29ed6cf76e5294cd401f13b9))
* **engine:** remove duplicate RunRegistry startup and fix related test warnings ([85c4444](https://github.com/www-zaq-ai/zaq/commit/85c4444dea1b7facf1f222f911c434fbbe398ef4))
* **engine:** run each batch iteration fully before the next fans out ([f81a1b0](https://github.com/www-zaq-ai/zaq/commit/f81a1b08f52053b8fe89612dd2cbe75f46e409b1))
* **engine:** scope shutdown sweep to local runs and harden async launch and fact lookup ([d1a1e13](https://github.com/www-zaq-ai/zaq/commit/d1a1e139713773673e5cb88d6e652eabcfadfb1a))
* **live:** prevent inline team-create from crashing assign_team_select ([060358b](https://github.com/www-zaq-ai/zaq/commit/060358b14d5679a69ed1957b2e7e550c2dddac02))
* **live:** run workflows off-channel to survive duplicate_join interrupt ([b1294f8](https://github.com/www-zaq-ai/zaq/commit/b1294f837ebdce344ce48c0482163d9e0b9e5065))
* **mattermost:** indicate bot should join a team, support private, dm and grouped dm channel types ([891d3d1](https://github.com/www-zaq-ai/zaq/commit/891d3d1f744532eee40816b32e101952a5450c56))
* **notification:** ability to send DM to channels [Action] Notify person is not honoring priorities ([eac2c78](https://github.com/www-zaq-ai/zaq/commit/eac2c78a7795fd3efc6e2e7ccf22bbcae56f3aaf)), closes [#524](https://github.com/www-zaq-ai/zaq/issues/524)
* **notification:** align email:smtp and email:imap for one single config path - [Action] Send notification message formatting is skipped ([f959525](https://github.com/www-zaq-ai/zaq/commit/f95952502c2496645c58cb6852bdf244ba19c384)), closes [#547](https://github.com/www-zaq-ai/zaq/issues/547)
* **web:** make conversation history table and filters responsive ([1dff5ef](https://github.com/www-zaq-ai/zaq/commit/1dff5ef5bd8379020349717c69c34a12e26773be))
* **workflow:** adjust channel message event name ([f2d2264](https://github.com/www-zaq-ai/zaq/commit/f2d2264438f31a43e200f720b160d6799a8e7699))
* **workflow:** remove phantom Iterate marker for explicit Batch delivery ([5eb3d91](https://github.com/www-zaq-ai/zaq/commit/5eb3d912d2aebaf2561e8450c3ac01ced53009b6))
* **workflow:** remove trigger page and add it to workflow ([8619408](https://github.com/www-zaq-ai/zaq/commit/86194085c1115837826d96a0bb200561f5ce97a4))
* **workflows:** add start namespace for trigger-to-first-node mapping ([1926c08](https://github.com/www-zaq-ai/zaq/commit/1926c087d119c290a4b119ef0847022be0293c8a))
* **workflows:** handle temporarily added events in triggers add popin - fixes [#514](https://github.com/www-zaq-ai/zaq/issues/514) ([2097d1b](https://github.com/www-zaq-ai/zaq/commit/2097d1badd77e33a11a523accca90930362ba8ac))
* **workflows:** make map an internal-only node type, author iteration via Batch ([9a1bd51](https://github.com/www-zaq-ai/zaq/commit/9a1bd517510c97939f30ead2b1dccfd5943baed9))


### Refactoring

* (BO) design migrate Metric card ([3b29b0e](https://github.com/www-zaq-ai/zaq/commit/3b29b0e73ea86a1f800dfb2e2d6cc3cddb2fa070))
* (BO) design migrate theme toggle in header ([33b6ef2](https://github.com/www-zaq-ai/zaq/commit/33b6ef21602210406c5528ba8b20b28bddfd7766))
* (BO) design migration and unification of component upsell card ([32fafe1](https://github.com/www-zaq-ai/zaq/commit/32fafe1d81dc743740c1637173d4581366eccf64))
* (BO) design migration diagnostic card ([c0f5ede](https://github.com/www-zaq-ai/zaq/commit/c0f5ede845b9871140bbd2e814c6125b0cf7b7a6))
* (Storybook) component organisation - removing unused components. ([91fefd8](https://github.com/www-zaq-ai/zaq/commit/91fefd8cb8a48aa7e5e597388f1af96fb3b15f19))
* (Storybook) fix dashboard service status table ([0140ae7](https://github.com/www-zaq-ai/zaq/commit/0140ae7c08e124cdc6db126bffff615149f89e49))
* add DesignSystem.Table list and grid with Storybook docs. ([78c8ffa](https://github.com/www-zaq-ai/zaq/commit/78c8ffa4132fff8f90958bc7c7e0f53477da8ed6))
* add hover and active (open) states to combobox trigger and select controls ([c50dd45](https://github.com/www-zaq-ai/zaq/commit/c50dd45111a800c1aef236a7d9111226fef12488))
* add semantic layout spacing tokens and layout.css utilities ([bcc041e](https://github.com/www-zaq-ai/zaq/commit/bcc041e5cb6ad61082c21a64181d3623c4db8473))
* **agent:** reference workflow agent by id via channel selection path ([55201f5](https://github.com/www-zaq-ai/zaq/commit/55201f5284f7d9c5c0b5aaba39f368b207c346a9))
* **agent:** resolve workflow agent selection on agent node ([31d1e6a](https://github.com/www-zaq-ai/zaq/commit/31d1e6afc7de9e5e112de53d986e7a5319136ba6))
* **agent:** reuse telemetry field sourcing, revert trace id suffix ([cb4acdb](https://github.com/www-zaq-ai/zaq/commit/cb4acdbd77ab50e54ff5045f6214fb05a7a1e7ec))
* align zaq-control-select height and padding with combobox trigger ([b045b65](https://github.com/www-zaq-ai/zaq/commit/b045b658b8b794f91fb5ef3e2858009ef704b635))
* **channels:** implement a process to monitor supervised listener and surface errors if any to feed listener status indication ([30deb94](https://github.com/www-zaq-ai/zaq/commit/30deb949691039aea5c767f71ac3faed8afa5338))
* **channels:** re-align code with new person/actor modules ([f5a8869](https://github.com/www-zaq-ai/zaq/commit/f5a88698463a2f42fc9fb5dfba9fd1d529388e64))
* clean input component to keep select a stand alone component ([13d9f80](https://github.com/www-zaq-ai/zaq/commit/13d9f8043232b53cfafe9da8dbb938ab58b143a1))
* consolidate BOModal Storybook docs with scrollable API reference ([7b8ee34](https://github.com/www-zaq-ai/zaq/commit/7b8ee34e9deec12a4713c1183e60f572127d1465))
* consolidate Input and SecretInput Storybook under Forms ([54deae7](https://github.com/www-zaq-ai/zaq/commit/54deae7113b05e408b78862d374651005449f65a))
* design migration for input to match design system ([8b154f3](https://github.com/www-zaq-ai/zaq/commit/8b154f30ab196f5d4a127c17ca4f95a19d852582))
* **engine:** decompose workflow tools and run contract per PR [#430](https://github.com/www-zaq-ai/zaq/issues/430) ([1e13c22](https://github.com/www-zaq-ai/zaq/commit/1e13c2298950a25af846f47f46acbc32d4c78b4f))
* **engine:** inject dependencies to make workflow modules testable ([46215b8](https://github.com/www-zaq-ai/zaq/commit/46215b89e4949cdd1ce0a19cc866def69fee0ccd))
* **engine:** replace string-ref pipeline lookup with inline node maps in DagBuilder ([46b2621](https://github.com/www-zaq-ai/zaq/commit/46b26214aa7c2add411eb1d111fa2233fd471e35))
* **engine:** revert google tool namespaces, rename StepApproval, dispatch via NodeRouter ([f5f4fc0](https://github.com/www-zaq-ai/zaq/commit/f5f4fc07293dcfc23e0be9f29289ddb69fe04b82))
* **ENV:** introduce new injectable Config module to load ENV and stabilize async tests ([a98cddd](https://github.com/www-zaq-ai/zaq/commit/a98cddd556fd8c029adf31f26c628efa5679da48))
* extract Checkbox as standalone DesignSystem component ([e5bd495](https://github.com/www-zaq-ai/zaq/commit/e5bd495552da7ad93d76691b8cbaa83f81b65ed3))
* extract components from dashboard page ([a1e9195](https://github.com/www-zaq-ai/zaq/commit/a1e9195be0c8cae45a942997d06581fa0cb2edac))
* extract DesignSystem.Button with variants and loading ([1a4becc](https://github.com/www-zaq-ai/zaq/commit/1a4becc9f03fa86cdb5de2f9c5086c8525f63f39))
* extract DesignSystem.Link with accent tone and storybook ([b783852](https://github.com/www-zaq-ai/zaq/commit/b783852f3a485f21cceca0a16e805e0b07533120))
* extract DesignSystem.MetricCard with optional link maps ([f029728](https://github.com/www-zaq-ai/zaq/commit/f029728d96cee0970ec4670c8aadedc241dbd735))
* extract Input and SecretInput from CoreComponents to DesignSystem ([83504ef](https://github.com/www-zaq-ai/zaq/commit/83504ef7bd758847ef6330771ef738f8897a9559))
* extract TabNav, SimplePagination, and EmptyState from people page ([fa4dd82](https://github.com/www-zaq-ai/zaq/commit/fa4dd82ffca2497dd60c97e63073d645ae6b8e13))
* extracting diagnostic card and status badge from bo_layout ([1d2a8d3](https://github.com/www-zaq-ai/zaq/commit/1d2a8d335205379efe06fe18af6239575f5ea301))
* fix design of tab nav component ([5374fb0](https://github.com/www-zaq-ai/zaq/commit/5374fb091a0684e5ce9225cd4d9a3d7d94106eac))
* fix documentation story of app_layout ([1132a1e](https://github.com/www-zaq-ai/zaq/commit/1132a1e162feb86a188eaedf9160507841b54845))
* improve Button story layout and icon rendering ([ad18338](https://github.com/www-zaq-ai/zaq/commit/ad183385d36695f682e957d49409e7ed6eb0b1a6))
* **Ingestion:** convert Zaq local items to Record struct. Phase 1 of supporting multiple data sources for ingestion ([59a63ad](https://github.com/www-zaq-ai/zaq/commit/59a63ad4a549ae2dde29477a48424934ba855ba1))
* **ingestion:** keep one path based on %Record{} and normalize at edges ([70b5a5e](https://github.com/www-zaq-ai/zaq/commit/70b5a5edec1cc45fc4ca141380e46cc314eb6940))
* **ingestion:** normalize sidecar inside Record attributes, surface errors, specs and docs ([0a11227](https://github.com/www-zaq-ai/zaq/commit/0a11227c6f19c7eaf1e14036782fce8610547172))
* isolate Storybook CSS in dev-only Tailwind build ([0569173](https://github.com/www-zaq-ai/zaq/commit/0569173277c61735116b88ba5d3650a727d7c95a))
* migrate BOModal confirm_dialog to design system tokens ([2528984](https://github.com/www-zaq-ai/zaq/commit/25289840c5d83f9e3b438227730546b18c828d8f))
* migrate checkbox component to design system tokens ([fdf4995](https://github.com/www-zaq-ai/zaq/commit/fdf49953077153b4f7940fa48c324a455fdb9ffe))
* migrate DesignSystem.Input textarea to zaq-control-text tokens ([8606c29](https://github.com/www-zaq-ai/zaq/commit/8606c29d7f53717b538d6890cd6fbaa906bc0125))
* migrate SecretInput to design tokens and drop password from Input ([50e600e](https://github.com/www-zaq-ai/zaq/commit/50e600e587e433e61db2c4bc2fd0ede7021166be))
* migrate TabNav to zaq design tokens and component Storybook ([c1012ab](https://github.com/www-zaq-ai/zaq/commit/c1012ab64de855b864967d37c35b8a5fb5d037eb))
* moving css classes to forms.css for cleaner documentation ([3f7f611](https://github.com/www-zaq-ai/zaq/commit/3f7f611495629029015d9216cfb821a10eeffe8b))
* neon animated border and soft focus glow on form controls ([d36eee1](https://github.com/www-zaq-ai/zaq/commit/d36eee180ca94ccf2d2bb76df4906aeb5af96eec))
* redesign the hover effect on drop downs ([c17bbd2](https://github.com/www-zaq-ai/zaq/commit/c17bbd292680731910b764aeb5e043d579b23bfe))
* reduce focus ring on combobox search input to accent border only ([b6041f8](https://github.com/www-zaq-ai/zaq/commit/b6041f8d32c48e76a5908704719f08a4e7b801b9))
* remove py-1 padding from searchable select options list ([629b11c](https://github.com/www-zaq-ai/zaq/commit/629b11c04c8e1bec4ed608f40eaf74480c631675))
* unify searchable select with form primitives and label layouts ([896aaab](https://github.com/www-zaq-ai/zaq/commit/896aaabfb726367611ff837e8ca1f45d5a306de4))
* update hover effect design on tertiary buttons ([d246d64](https://github.com/www-zaq-ai/zaq/commit/d246d643f1f73b9a01a977e2ba5de0ef5416e5aa))
* updating designs of input and select (including a compact version) ([d7fea4b](https://github.com/www-zaq-ai/zaq/commit/d7fea4b498b928fd1f956857d4fe5ac97015a862))
* **web:** extract agent trace panel into dedicated component ([17e5d24](https://github.com/www-zaq-ai/zaq/commit/17e5d24a8f780d6d8522435b0d03624180fc020e))
* wire DesignSystem.Link into metric overview sub-metric CTAs ([f01d727](https://github.com/www-zaq-ai/zaq/commit/f01d727b27bfd5d0d39721af3fed95704b616823))
* wire MetricOverview to DesignSystem.MetricCard ([122991b](https://github.com/www-zaq-ai/zaq/commit/122991b07c03f40bb527e3ad2eaf9134a11a92de))
* **workflow:** revert changes on update_sheet_values and support concat action ([1f0f924](https://github.com/www-zaq-ai/zaq/commit/1f0f9248a46db0987ba9f6a1171e8633ed93da8a))

## [0.13.0](https://github.com/www-zaq-ai/zaq/compare/v0.12.0...v0.13.0) (2026-06-18)


### Features

* **ingestion:** stream PDF image-to-text progress to BO jobs panel ([c83baed](https://github.com/www-zaq-ai/zaq/commit/c83baed5f8bb9fda7f6c12fc868b356303d61916))
* **onboarding:** record portal_registered consent for 409 email conflict ([604092b](https://github.com/www-zaq-ai/zaq/commit/604092bd9809dad481c2fa356fe0f48914887b43))


### Bug Fixes

* **channels:** display capabilities for all available channels (even if disabled or not configured) ([ffc9118](https://github.com/www-zaq-ai/zaq/commit/ffc9118375e6241c0407e4160201c257cbcebf2a))
* **channels:** normalize configs to ensure tokens are decrypted ([39f45ac](https://github.com/www-zaq-ai/zaq/commit/39f45ac21f7b25a2e4fee16b4a43d367d33577db))
* do not start the app if the SYSTEM_CONFIG_ENCRYPTION_KEY is not provided ([cc196c7](https://github.com/www-zaq-ai/zaq/commit/cc196c71f5ce791826eeac02c14bc638da3197e4))
* **ingestion:** keep dotted literals matchable in BM25 search ([30c9512](https://github.com/www-zaq-ai/zaq/commit/30c95125e5498ed6b810e7682c8c3ec21641b483))
* **ingestion:** preserve document headings by storing chunk title separately ([37ad45e](https://github.com/www-zaq-ai/zaq/commit/37ad45eedd8388b735ffc2454fb9318ac16d3315))
* **ingestion:** redact malformed progress lines and clamp prep indicator ([1bffa51](https://github.com/www-zaq-ai/zaq/commit/1bffa512cb11e83f6d5164b75932c1b60ef5c069))
* **ingestion:** volume base_path with default at volume base root ([dfced0e](https://github.com/www-zaq-ai/zaq/commit/dfced0e5cfca6c8b260fa9174efc0a04b2c38dd9))
* **live:** correct prep progress stage labeling and gate active prep jobs in O(1) ([a9065e1](https://github.com/www-zaq-ai/zaq/commit/a9065e1c93a55069229be925c1397418c8703f5e))
* **live:** prevent stale ingestion prep indicator on retry, straggler, and orphaned jobs ([f3b4151](https://github.com/www-zaq-ai/zaq/commit/f3b4151ae6255c0c19285845955592566c1ba95f))
* **onboarding:** scaffold zaq router credential on retry 409 conflict ([b8464e1](https://github.com/www-zaq-ai/zaq/commit/b8464e1eac22bb096bf785047c020723a99b289d))


### Refactoring

* (BO) chat shell layout and animation styles into a common css page ([dfd9302](https://github.com/www-zaq-ai/zaq/commit/dfd93024615d184b0445ccd2387f0f40d96e0e21))
* (BO) design migrate transcript component in chat page ([4fe0790](https://github.com/www-zaq-ai/zaq/commit/4fe0790fa3cc12987e138225d066cb1d9a3edf76))
* (BO) design migrate user bubble in chat ([602ae00](https://github.com/www-zaq-ai/zaq/commit/602ae009caa1932208378dd9b44a4ff46e56c538))
* (BO) design migration chat history sidebar ([6b48979](https://github.com/www-zaq-ai/zaq/commit/6b48979e90f00f5a0f12fd85a22345860abbc174))
* (BO) design migration composer element in chat ([ac9623f](https://github.com/www-zaq-ai/zaq/commit/ac9623f4d64fe393ea116522a41dcdd9c8bdf8a9))
* (BO) design migration header of chat ([58f4e17](https://github.com/www-zaq-ai/zaq/commit/58f4e1757a5fff813dd7ce791251bd5d50a11418))
* (BO) design migration of assistant bubble component and use cases ([4546f9d](https://github.com/www-zaq-ai/zaq/commit/4546f9dc1214fc29aca7f4dbeea53e744e7266cb))
* (BO) design migration of suggested prompts in chat page ([ca8001a](https://github.com/www-zaq-ai/zaq/commit/ca8001a9709d86a9a7e677a1257badbd625ee4f0))
* (BO) extract components from chat page ([14d6e35](https://github.com/www-zaq-ai/zaq/commit/14d6e35a3c456700e37dc787682f4d93654c0e5b))
* (BO) extract components from History page ([734345e](https://github.com/www-zaq-ai/zaq/commit/734345ea62c9a8a57b5911c9331afb1891e63a36))
* (BO) migrate design of status badge used in dashboard ([d987d4c](https://github.com/www-zaq-ai/zaq/commit/d987d4c7e911caf0fb095e8c282ed3b1a5d10692))
* (Storybook) adjuste stories of thumbs up/down/copy to show on assistant bubble ([f7619d7](https://github.com/www-zaq-ai/zaq/commit/f7619d7401a86cb4fbddff3f222130e64671c3c4))
* (Storybook) reorganising story documentation ([7ba4ee5](https://github.com/www-zaq-ai/zaq/commit/7ba4ee5e9cddf3c41ed31c779a642f2af7945522))
* **channels:** restore capabilities granularity and future proofing synthetic config ([2c4a1ea](https://github.com/www-zaq-ai/zaq/commit/2c4a1ea5f24c346aa95b2f51d1c44b29cfcf0f5a))
* **ingestion:** drop chunk title column and title generation ([ed949b9](https://github.com/www-zaq-ai/zaq/commit/ed949b95ab7643981607c756246f839693aa16ee))
* **ingestion:** make pdf/docx/xlsx converters injectable for testing ([1924326](https://github.com/www-zaq-ai/zaq/commit/19243261508b336acf9d337633d5ec2d546e3df4))
* **onboarding:** register in zaq before provisioning portal ([7908c35](https://github.com/www-zaq-ai/zaq/commit/7908c35a032e0f4d32d40caf5bdada3bf1a0b18d))

## [0.12.0](https://github.com/www-zaq-ai/zaq/compare/v0.11.0...v0.12.0) (2026-06-16)


### Features

* **accounts:** gate user portal provisioning behind explicit consent modal ([d1c5f6f](https://github.com/www-zaq-ai/zaq/commit/d1c5f6f4582eced542ac803d028a8817e96ec36f))
* **accounts:** provision ZAQ Provider credential on bootstrap onboarding ([870d9cf](https://github.com/www-zaq-ai/zaq/commit/870d9cf6f3d5efbb23fa1bdb5433a2208ac7734d))
* **agent:** add Apify MCP endpoint and fix Firecrawl remote URL ([caa4047](https://github.com/www-zaq-ai/zaq/commit/caa4047702f40d95d502302ea2d179e10b6eff91))
* **agent:** improve error classification with typed errors, budget exceeded message, and stream error suppression ([09d4f5e](https://github.com/www-zaq-ai/zaq/commit/09d4f5e09b7e0ed8fc9ff1ab547bd6fcf8bb4783))
* **agent:** refresh zaq router default model catalog with new llm, vision, and embedding models ([9b2b10c](https://github.com/www-zaq-ai/zaq/commit/9b2b10c74208d7fde862460c4e224242534b0fbe))
* **communication, AI agent:** stream llm response with full trace logging and live rendering ([b1efc03](https://github.com/www-zaq-ai/zaq/commit/b1efc03507ca26a7d4eb6b2b87f97e976412a33e))
* **live:** redirect to ingestion with persistent welcome flash on consent accept ([a5d085e](https://github.com/www-zaq-ai/zaq/commit/a5d085e4d3c42cacb405ca621896f034c5aed1c1))
* **live:** show spinner in save changes button during form submission ([3f21ea3](https://github.com/www-zaq-ai/zaq/commit/3f21ea361e14ede251beb091a590189537ac2944))
* **onboarding:** add portal liveness gate, dynamic consent copy, and zaq provider fallback ([13ca5a8](https://github.com/www-zaq-ai/zaq/commit/13ca5a8902fbb49cb86442954286e609f8a36426))
* **onboarding:** allow email override after 409 conflict in portal activation ([8c1ddec](https://github.com/www-zaq-ai/zaq/commit/8c1ddec346b802dacb8cc039f23c39dc22fe0599))
* **onboarding:** portal email sync, network payload, and scenario tests ([43d82fc](https://github.com/www-zaq-ai/zaq/commit/43d82fc12481ee5afab729109b2060cec844d21a))
* **onboarding:** pre-provision portal before account creation, add machine-conflict and email-override ([43c3424](https://github.com/www-zaq-ai/zaq/commit/43c3424cf4c5b5ca032c0e99847bfb78cd826b78))
* **onboarding:** replace machine_fingerprint with machine_signals payload and fix update_email arity ([23f0e05](https://github.com/www-zaq-ai/zaq/commit/23f0e05f62cffb1f9fd4fba478b51a14642be0a4))
* **system:** persist machine fingerprint to file for stable identity across restarts ([ad6b026](https://github.com/www-zaq-ai/zaq/commit/ad6b0269c35e5aa2f09ff27ef3d1c9d9c4ceb3ae))
* **web:** add icons to gear settings dropdown menu items ([4ac1aaa](https://github.com/www-zaq-ai/zaq/commit/4ac1aaaf35808846438bba7f487eb7a9a2c23c9c))


### Bug Fixes

* **agent:** default to openai/gpt-oss-120b and disable unavailable models ([945e279](https://github.com/www-zaq-ai/zaq/commit/945e27982aaa3fe1641d8dfe2294676c4181b324))
* **agent:** surface provider errors instead of empty bubbles and add title fallback ([2637d66](https://github.com/www-zaq-ai/zaq/commit/2637d66ed3b4e2a08f8d74a7d7d597d61afb7514))
* **AI agent:** correctly collect token usage measurements in messages and in dashboard telemetry ([5fa7373](https://github.com/www-zaq-ai/zaq/commit/5fa737338dbe35243f882347888ceeb69da7ab2f))
* **BO:** correctly assign trace field type in migration, remove storybook from coverage ([7eb1f40](https://github.com/www-zaq-ai/zaq/commit/7eb1f408ee609e0515f9e49b62ffd0dc76dab6dd))
* **live:** bypass req.test plug in e2e bootstrap to unblock dashboard moun ([3f57db8](https://github.com/www-zaq-ai/zaq/commit/3f57db815f42639af43a1b5ebd86b7fc04c82b8e))
* **live:** replace flash redirect with post-accept modal on portal consent ([339e648](https://github.com/www-zaq-ai/zaq/commit/339e648cd9d1bdac4e7a8979836592dcecb7d3d9))
* **live:** surface error outgoing to replace empty streaming bubble ([bb8d143](https://github.com/www-zaq-ai/zaq/commit/bb8d143e4ca51e254587625f6cf05d7249982a55))
* **onboarding:** add email to user consent popup ([71be075](https://github.com/www-zaq-ai/zaq/commit/71be07522d1bc2ea678c64ef4fc9a053ebf7762d))
* **onboarding:** atomic bootstrap provisioning via sage, nil endpoint default ([d10aa4e](https://github.com/www-zaq-ai/zaq/commit/d10aa4ec3948f71667535746fae4f8aef316d4fe))
* **onboarding:** load portal consent banner async and drop machine fingerprint ([fa12c70](https://github.com/www-zaq-ai/zaq/commit/fa12c70109aa9bffa639e641e92c638cb2a8aef7))
* **onboarding:** surface portal errors, dedupe requests, offline router ([83cc619](https://github.com/www-zaq-ai/zaq/commit/83cc619e0eda14ab921da9eebf91331fd8fa1348))
* **People:** no people creation for BO messages ([a611f83](https://github.com/www-zaq-ai/zaq/commit/a611f83be59e97164e57d1d8f9336d8dd8f5898c))
* **web:** restore tool_calls_popin component dropped in merge ([9ba1534](https://github.com/www-zaq-ai/zaq/commit/9ba15349cf2df2f2c63a8ea1ede6d5546fa86193))
* **web:** validate email format in portal consent modal ([623b489](https://github.com/www-zaq-ai/zaq/commit/623b489ccfc1c20d58dbbb4ee31cfa25b8971292))


### Refactoring

* (BO) design migration for the ingestion list view (table) and fixing grid doc in storybook ([e17c270](https://github.com/www-zaq-ai/zaq/commit/e17c2705ce6fd5b7bd6cd63badb52ff7a9246c23))
* (BO) design migration grid view - ingestion page ([39a2cbd](https://github.com/www-zaq-ai/zaq/commit/39a2cbda72b0232d69658aa5cf26db126002faf3))
* (BO) extract all components from Ingestion page ([4cc4416](https://github.com/www-zaq-ai/zaq/commit/4cc4416938c9b803872dc3cb6ef2f07ed49fd249))
* (BO) hiding button preview from grid in ingestion ([446959f](https://github.com/www-zaq-ai/zaq/commit/446959f25163324973ad3b02bc3c41da31c61cff))
* (BO) migrate design of component dropzone ([0498f39](https://github.com/www-zaq-ai/zaq/commit/0498f391e37ff489a6dfd199ed7e9f18523dadbe))
* (BO) Modal file preview UI migration - Ingestion ([db97064](https://github.com/www-zaq-ai/zaq/commit/db97064648a3d341b18ecfcccb7b04e6323a484a))
* (BO) status pill ui design migration ([21a1058](https://github.com/www-zaq-ai/zaq/commit/21a10585110aabbafaac4b1078e2886b571dc216))
* **accounts:** move portal provisioning into UserPortal.Onboarding boundary ([e1f5767](https://github.com/www-zaq-ai/zaq/commit/e1f5767b7b2e152aa8987cecd2557a05a40eaae2))
* **live:** extract portal consent lifecycle and zaq provisioner into dedicated modules ([ae5b876](https://github.com/www-zaq-ai/zaq/commit/ae5b876d8aba0597fc8cd6b7cae8931f69121122))
* **live:** move portal provisioning to dedicated module and decouple consent modal ([7e2f819](https://github.com/www-zaq-ai/zaq/commit/7e2f819b5157930f2f614c3385ecb049caf7294c))
* **onboarding:** centralize portal helpers and fetch metadata async ([dc6d7b3](https://github.com/www-zaq-ai/zaq/commit/dc6d7b33b5b248e162cd756a74bd01c67688db58))
* **onboarding:** unify blank?/1 helper and centralize portal client ([6d024aa](https://github.com/www-zaq-ai/zaq/commit/6d024aadfee59a4c79792f432aa7f1ce221a0a4d))
* **system:** send clear machine signals to portal without hashing ([3e207e0](https://github.com/www-zaq-ai/zaq/commit/3e207e0649f395b739b931a1a8d31972b1808ad4))

## [0.11.0](https://github.com/www-zaq-ai/zaq/compare/v0.10.0...v0.11.0) (2026-06-11)


### Features

* **bo-layout:** migrate sidebar styling to --zaq-* token system ([7ac2041](https://github.com/www-zaq-ai/zaq/commit/7ac2041e3301be821ed5702c1ca376b9ad7d5516))
* **design-system:** add gradient border to primary btn, shape tokens, and component styles layer ([82ef3b8](https://github.com/www-zaq-ai/zaq/commit/82ef3b8b00da63a9f2c992b62ebaedd582e69042))
* **design:** add zaq-text-* semantic text style classes from Figma ([f602b7b](https://github.com/www-zaq-ai/zaq/commit/f602b7b44b054b72e68b4262848e00812ac837fa))
* **ingestion:** add pluggable fts backend with native postgres default ([121fbb6](https://github.com/www-zaq-ai/zaq/commit/121fbb608c0d723bbc71b15e9fe8f81988d9f48e))
* **skills:** add /design-migrate skill for incremental styling migration ([126abfd](https://github.com/www-zaq-ai/zaq/commit/126abfde412e28fd7f9af4ba3bd98847a0927af1))
* **skills:** add file write restrictions to design-migrate skill ([7683824](https://github.com/www-zaq-ai/zaq/commit/7683824d6064ec88035d2280c58e5619332b273a))
* **skills:** add no-token-for-role annotation and forbidden example to diff format ([0943b63](https://github.com/www-zaq-ai/zaq/commit/0943b639aae0a305e7323d48400cb3eeff07b2e5))
* **skills:** add semantic token role-matching rule to design-migrate invariants ([8f3d7cf](https://github.com/www-zaq-ai/zaq/commit/8f3d7cfe6f23428486c271db3d74458c31395616))
* **skills:** add targeted e2e verification step to design-migrate skill ([8e9ec67](https://github.com/www-zaq-ai/zaq/commit/8e9ec67b2f89681b4abb371945ff64a4e49e888a))
* **storybook:** add button playground, semantic token rename, and btn.css ([631efd7](https://github.com/www-zaq-ai/zaq/commit/631efd7270ee61669a131ba54e9e23c12e4067d1))
* **storybook:** add component stories for BoModal, ChannelIcons, IconRegistry, MasterDetailLayout, and SearchableSelect ([58e5d7d](https://github.com/www-zaq-ai/zaq/commit/58e5d7db325a61cb2590757b0d36079dc45464b5))
* **storybook:** add foundations/palette story with raw CSS variable swatches ([2aba2dc](https://github.com/www-zaq-ai/zaq/commit/2aba2dcfb9fb6b3d3a9cdea880a27f42be8afac4))
* **storybook:** add foundations/spacing and foundations/typography stories ([06e5f8f](https://github.com/www-zaq-ai/zaq/commit/06e5f8f4f146be43a98689d2f56259686454be3e))
* **storybook:** add icon + icon-only button variations to playground ([8cffb5c](https://github.com/www-zaq-ai/zaq/commit/8cffb5ce69decea84880cd1b913c8bfb38f926aa))
* **storybook:** add line-height and letter-spacing token rows to fonts story ([31da8f6](https://github.com/www-zaq-ai/zaq/commit/31da8f610e4724c23a5a7f985373ca826db8f04a))
* **storybook:** add Text Styles page to Semantics using zaq-text-* classes ([d6cafaa](https://github.com/www-zaq-ai/zaq/commit/d6cafaab720c9c1254da50c2b128ce1506e51862))
* **storybook:** move colors/borders/shadows into new Semantic section ([0b0bc1e](https://github.com/www-zaq-ai/zaq/commit/0b0bc1e33365a04444cb21837a650d5829c3187a))
* **storybook:** reorganize stories into categorized sections with semantic tokens ([cc1fe1a](https://github.com/www-zaq-ai/zaq/commit/cc1fe1a843588674fffd7aac1173928f5e64bdc9))


### Bug Fixes

* **AI Agent:** increase Executor call to factory.await/2 timeout to match the config in factory module ([4befb57](https://github.com/www-zaq-ai/zaq/commit/4befb57fdc52facb6f66b7ab9cc0591481be238e))
* **CI:** storybooks e2e exclude from ci ([8b74e1a](https://github.com/www-zaq-ai/zaq/commit/8b74e1a903d558b61b999ec7f6a63c33c843d586))
* **communication channel,imap:** strengthen ssl management and harden flaky tests ([36bf63a](https://github.com/www-zaq-ai/zaq/commit/36bf63a571f828c22f62bbc0251d7ddaaedcb4fd))
* **config:** make dev.secret.exs import conditional to unblock CI ([2081ad9](https://github.com/www-zaq-ai/zaq/commit/2081ad961bc38438c7349bf1aa40e058981a7db3))
* **config:** make dev.secret.exs import conditional to unblock CI ([a64a8f9](https://github.com/www-zaq-ai/zaq/commit/a64a8f97cdd7222382eba99c50233913c1cfd773))
* **data source:** support jwt_bearer (service account) in auth credentials, implement for google drive ([1bd1c5a](https://github.com/www-zaq-ai/zaq/commit/1bd1c5a7d9ef068b0df0cc9aaac828055e513606))
* **e2e:** pin Storybook server to PORT=4000 MIX_ENV=dev to avoid port collision with test server ([a71aa73](https://github.com/www-zaq-ai/zaq/commit/a71aa732c445e13e61967c878f01a98fa4899a59))
* **foundations:** add unit to --letter-spacing-relaxed (1.0 → 0.1em) ([156f58c](https://github.com/www-zaq-ai/zaq/commit/156f58cc80feed42250097b48007e07aa037135e))
* **ingestion:** activate paradedb on fresh installs via probe-driven setup ([946f783](https://github.com/www-zaq-ai/zaq/commit/946f783448492a19c3524936b4f17b494a074209))
* **ingestion:** detect paradedb via functional probe and split fts ci ([8d76581](https://github.com/www-zaq-ai/zaq/commit/8d7658166baf4bf09abd6675f774c3f4300b9439))
* **ingestion:** keep paradedb detection from aborting open transactions ([234d246](https://github.com/www-zaq-ai/zaq/commit/234d246b69bcb622b97a73ac19c629f493a83522))
* **mcp:** enable context-awesome in MCP directory ([f8fde48](https://github.com/www-zaq-ai/zaq/commit/f8fde4863a30338fbbf585960954c4f5f075ae6a))
* **MCP:** enable firecrawl and tweetsave MCP now working with jido_mcp ([99ee44f](https://github.com/www-zaq-ai/zaq/commit/99ee44f648a192b67aaf605ebeb065cf892fe763))
* resolve merge conflict in config/dev.exs, apply storybook config changes ([5f3bf3d](https://github.com/www-zaq-ai/zaq/commit/5f3bf3dea2b536343f75393403d2477400eb27d9))
* restore configs ([edd5151](https://github.com/www-zaq-ai/zaq/commit/edd515118ed852993e6653ec33a3b774e243c88a))
* **skills:** add batching section to design-migrate skill ([eed021f](https://github.com/www-zaq-ai/zaq/commit/eed021ff5a224e11cf36d3418ac7c667c4a4d8a7))
* **skills:** add timing column to file write restrictions to prevent premature component edits ([c3c32f0](https://github.com/www-zaq-ai/zaq/commit/c3c32f0f68c28b85efa31e192d58c947e9e5d707))
* **skills:** address quality review findings in design-migrate skill ([b75f2d7](https://github.com/www-zaq-ai/zaq/commit/b75f2d70c3a066f1f4fdcd17cf120dd3198b9291))
* **skills:** convert design-migrate to directory structure (SKILL.md) ([08702e9](https://github.com/www-zaq-ai/zaq/commit/08702e9d4a723e873d12f5230a5109dc740a1d36))
* **skills:** replace 'app template' language with explicit file allowlist in Step 4/5 ([99cc6f4](https://github.com/www-zaq-ai/zaq/commit/99cc6f4e468c08e8760d39c6867544fca5a95020))
* storybook toggle switch dark mode ([a63fbce](https://github.com/www-zaq-ai/zaq/commit/a63fbce96ac282ca1e41d99e95488428552559b7))
* **storybook:** add missing surface-dark swatch to semantic colors story ([8b7758a](https://github.com/www-zaq-ai/zaq/commit/8b7758af18209912f5abefbf3183f1e4073e8227))
* **storybook:** convert index.exs to PhoenixStorybook.Index modules for correct sidebar ordering ([f9a7b9e](https://github.com/www-zaq-ai/zaq/commit/f9a7b9ec32202f5b0894606c5de81c4733a0f683))
* **storybook:** convert layouts index.exs to module format and set folder_index 4 ([27e3938](https://github.com/www-zaq-ai/zaq/commit/27e39382f988597eab1080222aea53a8e951a663))
* **storybook:** correct font token labels to --zaq- prefix ([4290762](https://github.com/www-zaq-ai/zaq/commit/42907622544e72f394e98dd46ed3fe6a734bfb10))
* **storybook:** escape HEEx {@ expressions in code display blocks ([948dd3b](https://github.com/www-zaq-ai/zaq/commit/948dd3bac90b1bc781de3788ec6d8e3a3919a7cf))
* **storybook:** fix 5 stories that failed the smoke test ([3487358](https://github.com/www-zaq-ai/zaq/commit/34873581e3247f06cc091843be1c7c523815dc9c))
* **storybook:** fix gitignore, reuseExistingServer CI safety, restore heroicons sparse, revert storybook version bump ([4403147](https://github.com/www-zaq-ai/zaq/commit/4403147d84ac7451aeaa150819cb266a02940af7))
* **storybook:** isolate ZAQ dark mode from DaisyUI via data-zaq-theme attribute ([4be4e0a](https://github.com/www-zaq-ai/zaq/commit/4be4e0a4e56598fcc1e2e5c83236580be618fd8c))
* **storybook:** pin Welcome to first position in sidebar via root .index.exs ([b2be326](https://github.com/www-zaq-ai/zaq/commit/b2be3266901141218d105c8a9eabcea24bd36ab0))
* **storybook:** poll for server readiness in globalSetup, commit story-urls sentinel ([299be81](https://github.com/www-zaq-ai/zaq/commit/299be813b85b6bbf676e0369dddb887210dbc0c4))
* **storybook:** prevent large scale bar overflow, update description ([94ef1e8](https://github.com/www-zaq-ai/zaq/commit/94ef1e8b581633f5f6a1efdd370b9b4be52d1dfc))
* **storybook:** rename index.exs to .index.exs so PhoenixStorybook detects folder index modules ([0944daa](https://github.com/www-zaq-ai/zaq/commit/0944daaa90fdabe3530d4dd8af3e8ff4ecdee017))
* **storybook:** replace .dark class shim with psb → data-theme dark mode bridge ([61744c7](https://github.com/www-zaq-ai/zaq/commit/61744c7a92806c2f5ed561c3a5902805b3725ec7))
* **storybook:** replace &lt;&gt; sigil sample in text_styles story to fix HEEx compile error ([6fed9f9](https://github.com/www-zaq-ai/zaq/commit/6fed9f9245e6004ee14e6081d46448fc0c0677c6))
* **storybook:** replace hero-plus/arrow-down-tray with icons already in Tailwind output ([1c0a744](https://github.com/www-zaq-ai/zaq/commit/1c0a74459518e049d8c76b9ad9fb8a6d29bdebfb))
* **storybook:** replace legacy --zaq-font-primary with --zaq-font-family-body in colors story ([306ea84](https://github.com/www-zaq-ai/zaq/commit/306ea84d2ffd006378e0b8988bf2b24e90a56294))
* **storybook:** update spacing story to --zaq-scale-* token names, add missing scale tokens ([c25312b](https://github.com/www-zaq-ai/zaq/commit/c25312b3e60b34ee4d801c0068acee81cecd35dc))
* **storybook:** use blue-400 for scale bars, fix overflow on large tokens ([1f8f427](https://github.com/www-zaq-ai/zaq/commit/1f8f42700d377adc02d8388807b0b58901da09f3))
* **storybook:** use filesystem discovery to find all stories, fix webServer url redirect ([2ef4f94](https://github.com/www-zaq-ai/zaq/commit/2ef4f940044557b4887a6877e3ed407ba613ebec))
* **storybook:** use globalSetup for story discovery to fix empty test registration ([2e3d673](https://github.com/www-zaq-ai/zaq/commit/2e3d673dc3617a5ff104894c1ed1a786b10e2276))
* **storybook:** wrap poll context in try/finally, skip final sleep on last attempt ([74de0e5](https://github.com/www-zaq-ai/zaq/commit/74de0e591538d97b50a791f2c2a0ebc8f49a6535))
* **tests:** eliminate port race in OpenAIStub and fix precommit failures ([eb2e799](https://github.com/www-zaq-ai/zaq/commit/eb2e799988141e29c1f3eb2d2b074e51b883c1db))


### Refactoring

* **auth credentials:** multiple config management per data source ([9ed4f31](https://github.com/www-zaq-ai/zaq/commit/9ed4f31a11993c1e2a603b24f34bd7e28307b9f7))
* **connect:** normalize scope parsing and document sync jwt refresh ([42473d4](https://github.com/www-zaq-ai/zaq/commit/42473d479a1541fccb2156d277862dd70600f19f))
* **css:** prefix all foundation and semantic tokens with --zaq- ([8fe0cd2](https://github.com/www-zaq-ai/zaq/commit/8fe0cd2fb6d1ee73f459a1f9a3b90fb4a4fca013))
* import dev.secret.exs at the end ([6e2f19f](https://github.com/www-zaq-ai/zaq/commit/6e2f19ffbcb7e21e5e490e2c23299f2dd4b294b4))
* **ingestion:** extract probe result helpers and bm25 query builder ([903e42a](https://github.com/www-zaq-ai/zaq/commit/903e42ae6e9edcf16750c2d30209c4490083fccc))
* split concerns to inject figma script on dev only ([edb88e7](https://github.com/www-zaq-ai/zaq/commit/edb88e79917e009993c316179ff9cc8d8be00e9f))
* **storybook:** consolidate e2e tests and move storybook to dev ([e203baf](https://github.com/www-zaq-ai/zaq/commit/e203baf63c781b7a2463d0ab7c722e46dade18bf))
* **storybook:** consolidate e2e tests and move storybook to dev ([62a08ee](https://github.com/www-zaq-ai/zaq/commit/62a08ee6101ca099c327a75651ed1c60cc9a6f6a))
* **storybook:** move core_components and chat_message stories to legacy_ui/ ([9ab10aa](https://github.com/www-zaq-ai/zaq/commit/9ab10aab95ab099f26da8a516d1e0a84b3e9f896))
* **storybook:** rename text_styles story to text_styles_deprecated ([402bdeb](https://github.com/www-zaq-ai/zaq/commit/402bdeb771be3f07287cd7f3d493e46bdb983748))
* **storybook:** strip raw palette sections from colors story ([d27072f](https://github.com/www-zaq-ai/zaq/commit/d27072f7967cb45f9adbacd0daf33b8d8390d228))

## [0.10.0](https://github.com/www-zaq-ai/zaq/compare/v0.9.0...v0.10.0) (2026-05-28)


### Features

* **BO:** Expose global base url field and use for oauth2 and webhooks ([bf4ba40](https://github.com/www-zaq-ai/zaq/commit/bf4ba409ee5635c45e112fc8e5160144ab583d5a))
* **Channels:** Automatic webhook ingress management ([4016dda](https://github.com/www-zaq-ai/zaq/commit/4016ddade429e8c7d396c78600aae81d988d7222))
* **Channels:** introduce a new upsert_message event with rules to abstract that away from internal ZAQ consumers ([ab000b9](https://github.com/www-zaq-ai/zaq/commit/ab000b9daa950367ab393e7570e8beee6df09c6a))
* **communication channels:** define a channel based formatter for outgoing messages rendering ([26f5625](https://github.com/www-zaq-ai/zaq/commit/26f5625a78e14c70358c3b194ad4ec1a346d6db5))
* **communication channels:** display an indicator for the ingress status of active channels ([80e7fe5](https://github.com/www-zaq-ai/zaq/commit/80e7fe5be63cc93d7f57403db0b18f8e9d9b5872))
* **communication channels:** Telegram (int ID) integration with editable message and tool call registration ([05bd3a3](https://github.com/www-zaq-ai/zaq/commit/05bd3a338cf6b633f733100d338758c6852233ab))
* **Communication:** standardize capabilities display across channel types ([95c7b10](https://github.com/www-zaq-ai/zaq/commit/95c7b105d15b8737e392f591ed8162f2ba6c4b35))
* **Communication:** start wiring up webhooks into communication channels ([51096d7](https://github.com/www-zaq-ai/zaq/commit/51096d7671b0867a72d8efd4b05ca21dbbce6d60))
* **Data Source:** adding Actions for data source interactions ([da8b7dc](https://github.com/www-zaq-ai/zaq/commit/da8b7dc227162f2e2d3807c76a2b6a6f8f1b5eb9))
* **Data Source:** wire capabilities implementation ([a9932ed](https://github.com/www-zaq-ai/zaq/commit/a9932edd3793d46056f61b85ad0e4607767dd7a5))
* **Data Source:** wire create and edit docs into new Actions ([72e9a25](https://github.com/www-zaq-ai/zaq/commit/72e9a259feb1cb37ef4d6ef63fd4da1e373c762c))
* **DataSource:** Integrate google sheets connector and merge into google_drive Data Source ([a37d122](https://github.com/www-zaq-ai/zaq/commit/a37d122a6fb0ffa6c27646935501548b59b89588))
* enable webhooks route in channels ([7186781](https://github.com/www-zaq-ai/zaq/commit/71867818183145681ad4a87bff9d74e238eb43c4))
* **engine:** add EventRegistry CRUD ops + Workflows sync + Event.new/3 compliance ([42e6aa8](https://github.com/www-zaq-ai/zaq/commit/42e6aa8da7eb87d24b6e59e3f4ab182939e11196))
* **engine:** TriggerNode threads event payload into workflow starting node input ([5597daf](https://github.com/www-zaq-ai/zaq/commit/5597daf9132f414bd57965328f45b9a981a84856))
* **workflow:** add contract to maintain on_success and on_failure path for the workflow ([b58a8da](https://github.com/www-zaq-ai/zaq/commit/b58a8daea80d499e9c553f5ce24c27185dae0842))
* **workflows:** add structured log storage to workflow step runs and email tools ([2b18822](https://github.com/www-zaq-ai/zaq/commit/2b18822e29f6782aea22796a5610a5d3b1375309))
* **workflows:** data model — zaq-3ux ([0583557](https://github.com/www-zaq-ai/zaq/commit/05835573b7a3501793ea22d189c9ea163693b50f))
* **workflows:** make workflows runnable from DB — zaq-3ux ([ba8226d](https://github.com/www-zaq-ai/zaq/commit/ba8226d571ef2fec9af1b438c9de2cd2643eb80d))
* **workflows:** move into engine namespace, rename ActionResult to StepRun, add structured logging with ([c8ad192](https://github.com/www-zaq-ai/zaq/commit/c8ad1925005ace4d190eee3434427d5f44c97148))
* **workflows:** replace raw steps map with typed StepNode/StepEdge embedded schemas ([bd243f4](https://github.com/www-zaq-ai/zaq/commit/bd243f42585dec104f4a75bc7fcb87f9d1e7b49c))
* **workflows:** replace trigger system with event-driven NodeRouter/PubSub architecture ([018a27d](https://github.com/www-zaq-ai/zaq/commit/018a27d6a2cd839c7a3319b9bc98f3fc7581d30c))
* **workflows:** wire DB-stored runs to Runic execution with ActionResult tracking, fix condition ([c6120d7](https://github.com/www-zaq-ai/zaq/commit/c6120d708f178eb332dbb6411af169a9edec0d75))


### Bug Fixes

* **agent:** max iterations ([b5187af](https://github.com/www-zaq-ai/zaq/commit/b5187aff3b833eafd924317025d2a5d900cccc5c))
* **agent:** stop using patch for max_iterations ([613302e](https://github.com/www-zaq-ai/zaq/commit/613302edd17be75946a6be4e0365c28d48e3ea4c))
* **bo:** add bulk delete for people with selection, confirmation modal, and gateway ([e79fbda](https://github.com/www-zaq-ai/zaq/commit/e79fbda6df9b7d02c6c76fc7be1e829054be8c4a))
* **bo:** address bulk-delete review findings — transactional delete, unified confirm bar, key normalization ([7e49cce](https://github.com/www-zaq-ai/zaq/commit/7e49cce3bdb49be594e1b7b9fd41e8b8f5ce575f))
* **Channels Config:** generalize Send message through NodeRouter ([f1ad3af](https://github.com/www-zaq-ai/zaq/commit/f1ad3af16a117739a6d00edce24a8539978e23ff))
* **communication channels:** deliver_outgoing :ok response handling ([e85ad16](https://github.com/www-zaq-ai/zaq/commit/e85ad1662c0eb9229054161f35bcfb4540c4538f))
* **Communication:** send_typing fix for non binary channel_id (i.e Telegram) ([f16a2b3](https://github.com/www-zaq-ai/zaq/commit/f16a2b3e2e635bd25693b4135743a5ac506ade58))
* **engine:** defer EventRegistry trigger load to handle_continue and make isolate_event_registry ([f0b28e8](https://github.com/www-zaq-ai/zaq/commit/f0b28e82ddfb620e0bd558b2d5258fb1a287b881))
* **engine:** EventRegistry.list_events/2 returns map instead of list ([f750415](https://github.com/www-zaq-ai/zaq/commit/f750415e4b9dce00ff73df9c5f28cb30fe4fd129))
* **test:** resolve module name collision and fix StepRun.statuses assertion ([ee2e4cc](https://github.com/www-zaq-ai/zaq/commit/ee2e4ccfdccbe90ede66907c5d1b6977035daf4e))
* **workflow:** creating and updating trigger sync the event registery ([298ce92](https://github.com/www-zaq-ai/zaq/commit/298ce9233e3e19ee990fc06fc1eb88d13a8dd66d))
* **workflow:** make event registry fire async and event name coupled with destination ([fa9b0ac](https://github.com/www-zaq-ai/zaq/commit/fa9b0acd16b6b3896b0bdb91362ba98078b7c9f9))
* **workflows/permissions:** address all PR review findings ([aadb282](https://github.com/www-zaq-ai/zaq/commit/aadb28288d5e2d834dc12f837b88a3827f0f6b92))
* **workflows:** auto-set started_at in create_action_result/3 ([c7431fa](https://github.com/www-zaq-ai/zaq/commit/c7431fac35052dcdfdda33ad23d1088f4f8c7204))


### Performance Improvements

* **channels:** only load ingress status indicator for active channels, allow deleting config with missing webhook ingress sub ([e49a0ac](https://github.com/www-zaq-ai/zaq/commit/e49a0acfe5928fde9a446c61fcd25302149079ee))
* **communication channels:** non blocking channel status load, non blocking formatting error ([8a38789](https://github.com/www-zaq-ai/zaq/commit/8a38789d3472454a436d0fa00f43eb1e46a924c2))


### Refactoring

* **Agents:** define an Error.format helper to use accross tools ([7eeadd6](https://github.com/www-zaq-ai/zaq/commit/7eeadd6e02ebebfba7cf21618634c9504d142820))
* **Agent:** Simplify data source tools code ([c094399](https://github.com/www-zaq-ai/zaq/commit/c0943992211850cf54c9da194da80c8d7a224fc7))
* **Channels:** adjust code path for code quality and upsert feature standardization ([2149b95](https://github.com/www-zaq-ai/zaq/commit/2149b95915106233644763b21d52bb207e7e29b1))
* **Channels:** Run webhook verification sync then enqueue Data Source webhook in Oban for async process ([df298b3](https://github.com/www-zaq-ai/zaq/commit/df298b382d249a6b62c3a305995ad58bbaef8d86))
* **Channels:** wire messages to new upsert_message feature ([2ba875e](https://github.com/www-zaq-ai/zaq/commit/2ba875ec364018a0dedb7b232f345bda408c0352))
* **data source:** resolve integration module in bridge ([76c2ed9](https://github.com/www-zaq-ai/zaq/commit/76c2ed9e2b61d65b9ca45ae765ccb93de490f50a))
* extract MapUtils, unify valid_rights contract, and add Action default callbacks via __using__ ([45edf8a](https://github.com/www-zaq-ai/zaq/commit/45edf8adedc65521192a423ffc2b77a956c9ea1d))
* Implement code review comments on channel's webhook ([49ffdde](https://github.com/www-zaq-ai/zaq/commit/49ffdde3fe9e956a6e3a843f3a4cbdea75fa4fc0))
* **NodeRouter:** deprecate call/ clauses ([c0a36dd](https://github.com/www-zaq-ai/zaq/commit/c0a36dd06250435b5ce8c49e99fc1a0af5bd1139))
* **permission:** move Ingestion.Permission to Permissions.DocumentPermission ([cf9219c](https://github.com/www-zaq-ai/zaq/commit/cf9219c511e83cc7ee1043fa60ce33ec436ea7a4))
* **System:** extract mcp, ai credentials and auth credentials into dedicated module files ([d39b28a](https://github.com/www-zaq-ai/zaq/commit/d39b28a77e63ba6ac2b051b858cdd750615ad6cd))
* **System:** extract remaining logic to keep routing only in system config live ([72e67ce](https://github.com/www-zaq-ai/zaq/commit/72e67ce797d806fd5548eaf4352ec64d663bdeea))
* **tools:** add output schema for tools for the workflow ([202fa9a](https://github.com/www-zaq-ai/zaq/commit/202fa9a6792b005ccaa8220e73e1a09200666bae))

## [0.9.0](https://github.com/www-zaq-ai/zaq/compare/v0.8.1...v0.9.0) (2026-05-15)


### Features

* **channels:** add datasource bridge and jido connect flow ([9908e95](https://github.com/www-zaq-ai/zaq/commit/9908e952e045606e7afedc3026a69e208e411653))
* **Data Source:** add data sources infrastructure and oAuth2 credentials support ([2843fea](https://github.com/www-zaq-ai/zaq/commit/2843fea50ca438131c71db2eb43c4e5e8773f47d))
* **Data Source:** request permissions with Records ([f11c3ab](https://github.com/www-zaq-ai/zaq/commit/f11c3ab59a2e0ef1b60055230753a7637ef171fd))
* **engine:** add :get_person engine api handler and update agent/pipeline dispatch to use it ([5407c88](https://github.com/www-zaq-ai/zaq/commit/5407c88821a1e7b88b2a0e7fbde42b524ebf9a2f))
* **system-config:** restore auth credential actions and rename tabs ([71c5799](https://github.com/www-zaq-ai/zaq/commit/71c5799d868927a9350c7cb9fe25855b53c5f864))


### Bug Fixes

* **agent:** enforce tool calls for listing queries, fix no-permission doc access, and hardcode answering ([056ffca](https://github.com/www-zaq-ai/zaq/commit/056ffca6b538a01b833974c55b723aa63e7015da))
* **agent:** replace list_knowledge_base_files with knowledge_base_overview, enforce tool_choice, fix ([36cc077](https://github.com/www-zaq-ai/zaq/commit/36cc07753f63a96aa65579ef8d402ffd476f8a58))
* **agents:** display stale tool keys with Removed badge and unblock editing ([abe8270](https://github.com/www-zaq-ai/zaq/commit/abe827042a79250b3194a2be719eecc7fe4b7826))
* **channel:** add incoming context to executor path ([dd64e32](https://github.com/www-zaq-ai/zaq/commit/dd64e3214186b32f6582df10a2bb830d07cd1049))
* forward telemetry dimensions through agent pipeline and increase ask timeout to 300s ([c8b958a](https://github.com/www-zaq-ai/zaq/commit/c8b958a029586f33fa178495f6531e10bc2c4082))
* **ingestion:** base ingested status on chunk existence instead of DB record presence ([68c4ff8](https://github.com/www-zaq-ai/zaq/commit/68c4ff8d319830f5a30c1bbd71860bafaec3dbde))
* **ingestion:** case-insensitive @ mention suggestions and rename regression tests (issue [#330](https://github.com/www-zaq-ai/zaq/issues/330)) ([0bdae1c](https://github.com/www-zaq-ai/zaq/commit/0bdae1cb28da36d264a84b7f0244b46904879667))
* **ingestion:** clean up orphaned document records when deleting a folder ([fb05282](https://github.com/www-zaq-ai/zaq/commit/fb05282de5ed1048f5efcfcf765630067ebae63a))
* **ingestion:** detect sidecar .md files by filesystem name matching instead of DB lookup ([a85b92d](https://github.com/www-zaq-ai/zaq/commit/a85b92df70f146cfb8a2bc65b9b0f0f52211563f))
* **ingestion:** handle legacy absolute-path sources in rename, delete, and upload tracking ([f64ad99](https://github.com/www-zaq-ai/zaq/commit/f64ad99b46bf55f9a1c533d6b77e6c3780bb875d))
* **ingestion:** include no-permission-rows docs as public by default in list_accessible_documents ([0617ae4](https://github.com/www-zaq-ai/zaq/commit/0617ae4a4a6efee23a81f0c4861ee9c2a421707a))
* **ingestion:** prevent track_upload from wiping ingested content on re-upload ([d92d29b](https://github.com/www-zaq-ai/zaq/commit/d92d29b0d53c935e57434e132d7d29eaa5091634))
* **ingestion:** rename tool and reject side car count ([43799da](https://github.com/www-zaq-ai/zaq/commit/43799da25c6deb446236fcc4fa5fad09a5462b85))


### Refactoring

* **BO:** split the system config tabs into specific components ([e4cd26f](https://github.com/www-zaq-ai/zaq/commit/e4cd26f61a6c7d9fa5dbf4050b787e3e4ef7716f))
* **channels:** align BO livechat with new Event passing logic, unify error management ([830fdbf](https://github.com/www-zaq-ai/zaq/commit/830fdbfc9bb622fb00a801463b570e0401f6452d))
* **channels:** node route dispatch chains multiple hops, leverage noderouter on Agents and Zaq -&gt; Channels node calls ([2635ed8](https://github.com/www-zaq-ai/zaq/commit/2635ed81663c3a48cef1dd1e0591b74e5bdee959))
* **channels:** restructure bridge behavior and split Zaq technical domains from communication domains ([a03ee66](https://github.com/www-zaq-ai/zaq/commit/a03ee661682485c2734866d30f6cb7eb374a4e43))
* **channels:** route channel delivery through API event boundary ([dba6162](https://github.com/www-zaq-ai/zaq/commit/dba61623d81fa8fd24b9b544d5886bc2afd42f80))
* **data source:** implement code changes to comply with code review ([a05bf13](https://github.com/www-zaq-ai/zaq/commit/a05bf13468f86a83629cdb4d2a72061ea3957049))
* **Endpoints:** enable channel specific routes ([40597f2](https://github.com/www-zaq-ai/zaq/commit/40597f234e2e38bd20d20249e768588df6dd9e6f))

## [0.8.1](https://github.com/www-zaq-ai/zaq/compare/v0.8.0...v0.8.1) (2026-05-08)


### Bug Fixes

* **agents:** cover it with e2e tests ([1bbcf84](https://github.com/www-zaq-ai/zaq/commit/1bbcf844f1b9b8a73efe19835df2adb71d769228))
* **agents:** fix OpenRouter case mismatch and add full E2E coverage ([8a22216](https://github.com/www-zaq-ai/zaq/commit/8a2221667fea94fbdbbd44b0b2231fb4ffef4a37))
* **agents:** scroll to flash/inline errors after DOM reflow using requestAnimationFrame ([4424f6e](https://github.com/www-zaq-ai/zaq/commit/4424f6e240a7756f6060e550448d4127485f1bef))
* **agents:** when error occurs on agent page it scrolls for user to know what's the error ([2f8e183](https://github.com/www-zaq-ai/zaq/commit/2f8e1832a8fd3187d11c06785712d4419f1df1b8))
* **chat:** add delete chat confirmation modal and new_chat event ([f748618](https://github.com/www-zaq-ai/zaq/commit/f748618f67c4d39f2a2a897c29216278a8976084))
* **chat:** delete chat button ([f0b0dc3](https://github.com/www-zaq-ai/zaq/commit/f0b0dc37a330370ed75a0ff13d8999abd4c726da))
* **chat:** rename clear-chat to new-chat button and fix e2e selector ([1f937fe](https://github.com/www-zaq-ai/zaq/commit/1f937fe52f403ebd119933b16637034921fa7fb6))
* **ci:** add a summary for the releases ([7762b3f](https://github.com/www-zaq-ai/zaq/commit/7762b3f1790877a53ff89e402ba62fd649df932b))
* **ci:** compile into _build/test-e2e to eliminate double Elixir compilation in E2E workflow ([2b1290f](https://github.com/www-zaq-ai/zaq/commit/2b1290f42a26904627e637940fdf3c6882e18097))
* **e2e:** stabilize remove-MCP test by waiting for modal close ([17a44e3](https://github.com/www-zaq-ai/zaq/commit/17a44e3209303ae93e58700606561fd502084b52))
* **ingestion:** allow cancelling processing jobs and stop pending chunk workers ([33f800c](https://github.com/www-zaq-ai/zaq/commit/33f800c70e7a6b5ad03946da54f9f9ae48c8917c))
* **ingestion:** atomic stop_job, race guard, friendly error messages, and embedding settings link ([88f68ae](https://github.com/www-zaq-ai/zaq/commit/88f68aea1a8e185e32f25c2d6e703771812f1a32))
* **ingestion:** cancel stuck jobs, stop chunk retries, and surface fatal errors to the user ([b5b39c5](https://github.com/www-zaq-ai/zaq/commit/b5b39c5614c0272337547f7eb2eacbf64bd043cf))
* **ingestion:** handle folder drops with batching, relative paths, and in-progress upload guard ([d68d554](https://github.com/www-zaq-ai/zaq/commit/d68d554875fc1b6e244cfea5a2514da7ff1362f3))
* **ingestion:** readEntries error handling, queue cleanup on destroy, skipped reset on upload, path tooltip, event doc ([a1da0d2](https://github.com/www-zaq-ai/zaq/commit/a1da0d23cdf32c4529150ef7e2f1aac5e1763772))
* **ingestion:** replace manual FS rollback with Sage saga and fix metadata fragment cast ([e914179](https://github.com/www-zaq-ai/zaq/commit/e9141794a6c9524dd8f699a2bd901d466f53f75a))
* **ingestion:** solid sanitize_bm25_query — fix Unicode whitespace and idempotency ([01e6f55](https://github.com/www-zaq-ai/zaq/commit/01e6f55f600c792d0e70b7713207a908c3cd38c8))
* **ingest:** update document sources and sidecar metadata when renaming a folder (issue [#331](https://github.com/www-zaq-ai/zaq/issues/331)) ([98a5456](https://github.com/www-zaq-ai/zaq/commit/98a5456195448f64f7f28a262ff9983abf7ea789))


### Refactoring

* **ingestion:** make directory rename DB updates atomic via Ecto.Multi ([6343212](https://github.com/www-zaq-ai/zaq/commit/6343212ff47e7eedf36b8b35202fec5841a5675f))

## [0.8.0](https://github.com/www-zaq-ai/zaq/compare/v0.7.3...v0.8.0) (2026-05-05)


### Features

* **agent:** enable custom AI agents declaration through the BO with chatting ability to a specific agent ([70ad5a8](https://github.com/www-zaq-ai/zaq/commit/70ad5a8f45b6fab2812c9cbb412449fd56f3d53f))
* **agent:** implement per-person Jido server spawning with unified routing across Pipeline and Executor ([e9c4413](https://github.com/www-zaq-ai/zaq/commit/e9c4413fe335eb18cf53f66d0e3b78dce706aea5))
* **agent:** replace on_status closure with Status.broadcast and gate PromptGuard in Api ([3918dc2](https://github.com/www-zaq-ai/zaq/commit/3918dc2bec0ab30b84110391f8c0bc02a5607d7f))
* **agent:** rewire agent pipeline with Status.broadcast, PromptGuard gating, and ChatLive ([7192eb7](https://github.com/www-zaq-ai/zaq/commit/7192eb7d3f1b043f0f9e9f864f744446d2f5fbcc))
* **agent:** scope server IDs by channel, add per-agent idle TTL, and inject history context on cold spawn ([2a13c05](https://github.com/www-zaq-ai/zaq/commit/2a13c0551cc76e74c91c366def3eacb649af0272))
* **agent:** scope servers per conversation and add per-agent idle TTL and memory context size config ([d9c4f86](https://github.com/www-zaq-ai/zaq/commit/d9c4f8634f4bace6b5431a2cc0d667a4cda3f2ac))
* **agents:** Make tools selection friendlier ([b623b8f](https://github.com/www-zaq-ai/zaq/commit/b623b8fd8e825d7a01807598530cfda8b5d28d41))
* **agent:** unify answering path through Executor as single execution boundary ([9c426d8](https://github.com/www-zaq-ai/zaq/commit/9c426d869472c6cb03a0ce84f8754b58cfb9cf41))
* **AI Agent:** Add MCP support to AI Agents with runtime configuration capabilities ([6d1d27e](https://github.com/www-zaq-ai/zaq/commit/6d1d27e819d5b749136d9520b3cd6fffe892cba4))
* **AI Agent:** implement draining strategy when stopping an Agent' server ([f61add4](https://github.com/www-zaq-ai/zaq/commit/f61add41188fcdfa13d5a0f8efe2c6e7e9e1e7d8))
* **AI Agents:** Wire communication channels to custom AI Agents ([51dac43](https://github.com/www-zaq-ai/zaq/commit/51dac43c1e4fc45bd3141eb55dcc7f74ac80355a))
* **AI agents:** wire more Jido.Action into AI Agents tools selection ([164adb4](https://github.com/www-zaq-ai/zaq/commit/164adb4200d18cc7ed4607f4728b40013eb3ecbb))
* **AI Agents:** Wire tool calling abilities into AI agents, wire logs from jido telemetry into console ([ccda430](https://github.com/www-zaq-ai/zaq/commit/ccda43064b6ecf5597ac1ba4c1cf2084d18c5336))
* **AI Agent:** wire tool calls to BO livechat and history conversations ([2154caa](https://github.com/www-zaq-ai/zaq/commit/2154caa0ecab74be64421c92a62177161248eb87))
* **answering:** provide a tool call to understand the file system ([b2d15b5](https://github.com/www-zaq-ai/zaq/commit/b2d15b5871d8d0a4e73b66a016c2be319368c0f3))
* **BO:** add update badge when a new Zaq release is available ([fb12db2](https://github.com/www-zaq-ai/zaq/commit/fb12db23fe8689d09f7018c24119a154d9796dad))
* **chat:** add content filter with [@mention](https://github.com/mention) autocomplete, folder scoping, and interactive file tokens ([4c1b0d6](https://github.com/www-zaq-ai/zaq/commit/4c1b0d692bbf67efa2dc11d5514e6775a1353647))
* **chat:** allow selecting a folder as a content filter from autocomplete ([fb96773](https://github.com/www-zaq-ai/zaq/commit/fb967736bef6c6e858811fcc91f6fc39459a02ed))
* display notice when trying to add MCP to agent with no active MCP available ([0b0e8c4](https://github.com/www-zaq-ai/zaq/commit/0b0e8c4c8f1631faa11ef79017c7b3c83f33188c))
* First connection doesn't require login anymore ([81f0494](https://github.com/www-zaq-ai/zaq/commit/81f0494671c19d7f01682bb7ab0154f52880fd00))
* implement simplified user onboarding at first login ([e853e59](https://github.com/www-zaq-ai/zaq/commit/e853e590534178b10e7324f8156c536fcb108d43))
* **ingestion:** add PPTX to Markdown conversion support ([dcf58a6](https://github.com/www-zaq-ai/zaq/commit/dcf58a6dbe55e58dbb0f7339997cbbe6eff301b1))
* **ingestion:** add PPTX upload support with PowerPoint icon ([4e471d0](https://github.com/www-zaq-ai/zaq/commit/4e471d094296e76ded86b4ac150aa2ca5413aa63))
* **MCP:** enable administration of MCPs with connectivity test ([a6cd73f](https://github.com/www-zaq-ai/zaq/commit/a6cd73f7bab7efd1ac29ebc97ad6958b3a0c4ed9))
* **MCP:** wire MCP to agent at runtime ([831ec45](https://github.com/www-zaq-ai/zaq/commit/831ec450f2decb051c51bfdb27bddf5b87112606))
* **readme:** add Discord badge ([06175f1](https://github.com/www-zaq-ai/zaq/commit/06175f1e6c60d93ca0db00d9a71774dbda8d2c3e))


### Bug Fixes

* **agent/channels:** update tests for async from_listener and derive_scope/2 refactor ([9ec10ff](https://github.com/www-zaq-ai/zaq/commit/9ec10ff696bf41e9b4f19081e7cd77d3eb93d501))
* **agent:** centralize pipeline error messages across channels and add error message tests ([4f3c5df](https://github.com/www-zaq-ai/zaq/commit/4f3c5df4b895c8a003a766ec681bb9c847892d8c))
* **agent:** handle history ([9787f99](https://github.com/www-zaq-ai/zaq/commit/9787f9921659dff5d51a40254c874018db530b5c))
* **agent:** harden permission model, remove silent nil bypass, and clean up LLM config ([276467b](https://github.com/www-zaq-ai/zaq/commit/276467b06a8120ecf06bdd7164c404a9f333bef3))
* **AI Agents:** properly surface agents mapping config to email mailboxes ([4b53827](https://github.com/www-zaq-ai/zaq/commit/4b5382724b5460696d92f0d8b32b70df85af141c))
* **AI Agent:** system prompt refresh logic ([d5727ea](https://github.com/www-zaq-ai/zaq/commit/d5727ea793cb871a6e7abb3366adb1d428f5e05e))
* **answering:** wire logprobs to confidence scoring and fix stream crash ([5e9e569](https://github.com/www-zaq-ai/zaq/commit/5e9e5695a3568d9b74cebdea8dde8e009c1255f8))
* **ci:** grant statuses:write to test job so Coveralls can post coverage status back to GitHub ([5924d4a](https://github.com/www-zaq-ai/zaq/commit/5924d4ae93e0f934a9fbd4f9d4dcef32065c6d3c))
* **filter-content:** address PR review findings — safe atom coercion, NodeRouter error logging, ConnectorRegistry tests, dotted-folder heuristic, and ingestion docs ([f813c72](https://github.com/www-zaq-ai/zaq/commit/f813c729af9f9d9c01df6af75ddf7fe459d183bf))
* **flash:** add auto-dismiss to BO flash with configurable duration and cover it with one e2e test ([13c8a5b](https://github.com/www-zaq-ai/zaq/commit/13c8a5b03d1b03e9ece2f39e66efda20b686c94e))
* **ingestion:** replace Task.async_stream :infinity timeouts with bounded defaults (90s chunks, 10s file stats) ([efb1823](https://github.com/www-zaq-ai/zaq/commit/efb1823af2898de463e3efd1f9483e9cdb09c8a8))
* **llm_db:** pre-create modality atoms before snapshot load to match LLMDB.Application boot contract ([195575c](https://github.com/www-zaq-ai/zaq/commit/195575ce93e822b25b65033ef591ab6e85ce5dc4))
* **llm-config:** remove json_mode and logprobs also enforce user to pick models have tools enabled based on llm_db ([b060fd5](https://github.com/www-zaq-ai/zaq/commit/b060fd5cc026d5d5ded5e42cc97877c720a5ed24))
* **local-installation:** update zaq-local ([ef762b5](https://github.com/www-zaq-ai/zaq/commit/ef762b54a0c0f72dab374dc9cc706cf3d3f09610))
* **mattermost:** restart listener on config changes ([ca06960](https://github.com/www-zaq-ai/zaq/commit/ca06960435ee2a1c2ea5c6021f6589f512126b52))
* **MCP:** one client_info name per mcp endpoint to avoid collisions, hide incompatible predefined MCPs for now ([16048f2](https://github.com/www-zaq-ai/zaq/commit/16048f29bcc7353e4db4862d3698d28a727d56c1))
* **quality:** add git_hooks and mix quality ([5bd2330](https://github.com/www-zaq-ai/zaq/commit/5bd23302f8e2c4289277dc717fea99173bea4a78))
* reconnect metrics to dashboard ([9a91ea6](https://github.com/www-zaq-ai/zaq/commit/9a91ea6864d5f6f030864254d59fe181e4272fbb))
* **release:** fix llm_db dep ([5eb4a36](https://github.com/www-zaq-ai/zaq/commit/5eb4a36489d00fb2e4ce2f289de6c811e0d708b1))
* **retrieval:** disable json mode when conversation history is present ([cbe974a](https://github.com/www-zaq-ai/zaq/commit/cbe974ac0b4052cee289a147a385419d27ad6c2f))
* **retrieval:** remove prompt template and make it hardcoded ([e381251](https://github.com/www-zaq-ai/zaq/commit/e38125142c150a07bb7cc7b26db8c5b0ae0b736b))
* **retrieval:** replace JSON-mode output with markdown parsing in retrieval agent ([d698b21](https://github.com/www-zaq-ai/zaq/commit/d698b21afba750cc9494e750cf8c189f849dd527))
* **source-filtering:** enhance the search filter with js functionality ([1abc960](https://github.com/www-zaq-ai/zaq/commit/1abc9602592eec6cac736f9e8db80a9f1487e2e8))
* support async EventHop types in NodeRouter.dispatch/2 ([a649325](https://github.com/www-zaq-ai/zaq/commit/a649325dda2c6efcb8cb40d69bc6a7850f3615c7))
* **telemetry:** trunc dimension label to avoid overflow ([44b39e9](https://github.com/www-zaq-ai/zaq/commit/44b39e9632c3abb6d20d7dd2f9b27d3eb581894c))


### Refactoring

* adjust code to avoid crashes from the new badge component ([dfca395](https://github.com/www-zaq-ai/zaq/commit/dfca39508b4783749e32e92034bbaa1daba995d9))
* **agent:** centralise all provider/spec/opts logic into ProviderSpec ([98d36d9](https://github.com/www-zaq-ai/zaq/commit/98d36d9000c1b653dc96e04dc18b935fb6ee82bb))
* **agent:** clean server manager and executor from history context and move it to factory ([11cf36a](https://github.com/www-zaq-ai/zaq/commit/11cf36aea3705a6e5226bc1289a653890d22c43b))
* **agent:** consolidate LLM/AnsweringAgent into Factory and fix e2e LLM tab isolation race ([8e1fdcf](https://github.com/www-zaq-ai/zaq/commit/8e1fdcf752f0c49d357ec80c689b8a79b2ad89ad))
* **agent:** extract provider/URL logic from Factory into ProviderSpec ([8b33dc2](https://github.com/www-zaq-ai/zaq/commit/8b33dc2f0497039c7f5cae74a149b79a1dc2e771))
* **agent:** migrate answering and retrieval to Jido AI agent with ReAct tools via ReqLLM ([ffe6149](https://github.com/www-zaq-ai/zaq/commit/ffe614998436066b56f20b1adfe7445b5c683f02))
* **agent:** move answering_configured_agent into Answering and unify generation_opts in Factory runtime_config ([cfbf570](https://github.com/www-zaq-ai/zaq/commit/cfbf570582d5e59a096d81cac8f1b76e06897f36))
* **agent:** move history loading out of ServerManager into Executor, with HistoryLoader owning routing ([facd1ef](https://github.com/www-zaq-ai/zaq/commit/facd1effbb867993f7160a1e9a79dd43d94979bb))
* **agent:** move provider/URL logic to Factory, remove last_active state, align pipeline answering with Outgoing ([d8bf39f](https://github.com/www-zaq-ai/zaq/commit/d8bf39f4adc88988babcd5658f5ca932df669e51))
* **agent:** remove AgentController, its routes, and dead prompt-guard output check from pipeline ([b3c156a](https://github.com/www-zaq-ai/zaq/commit/b3c156a0ba63462d3c6373c6b75c0a124fdb7b84))
* **agent:** replace hardcoded provider lists with llm_db lookups, consolidate fixed_url to Factory, ([471d42e](https://github.com/www-zaq-ai/zaq/commit/471d42edce368f08d29cddaa312472b1a72689ba))
* **agent:** replace LangChain/LLMRunner with ReqLLM across all agent modules ([d2eed0d](https://github.com/www-zaq-ai/zaq/commit/d2eed0d2e84e3262509cf63113976537e366ae4f))
* **AI Agent:** Cleanup the contracts for Agents &lt;-&gt; Process in ServerManager ([a88eaa8](https://github.com/www-zaq-ai/zaq/commit/a88eaa84edfb3e3cd4efffd87b2a6186aca334a4))
* **AI Agents:** Properly wire Agent server hot patch/shutdown strategy when config values change, harden new history loading selection extraction. ([f7ee723](https://github.com/www-zaq-ai/zaq/commit/f7ee7231104710c02b70c4b654b07c579b12f1dc))
* **AI Agents:** Provide system prompt from config at ask, wire telemetry ([4af2f79](https://github.com/www-zaq-ai/zaq/commit/4af2f79120a854d6136242705bf617ef40799fd5))
* align custom server_id and mcp management, eliminate duplicates ([75e1c2e](https://github.com/www-zaq-ai/zaq/commit/75e1c2ec2eb6344118b88a7b6524fbf177d9a03e))
* **answering:** conversation_enabaled true so communication channel can use answering agent. ([20cea28](https://github.com/www-zaq-ai/zaq/commit/20cea2869e40ffe2d4c2b44e8e372e1a4ea01007))
* avoid risk of orphaned agent processes, fix test flakiness in local test db ([b099f50](https://github.com/www-zaq-ai/zaq/commit/b099f50dd1ff1fd1bba6ad0139ab4e6b18d8927e))
* **BO:** stop duplicate DB calls on AI agents interactions ([6fbc219](https://github.com/www-zaq-ai/zaq/commit/6fbc219befb1735f61a261a126461f9b369297d7))
* bump jido_ai deps and align agent selection in channels ([bd9cd09](https://github.com/www-zaq-ai/zaq/commit/bd9cd0997bb62757a5cbd415c23891dc4288a00f))
* code format fix ([8c79b95](https://github.com/www-zaq-ai/zaq/commit/8c79b95f82483785506bc8975e2ec66dbc4f4366))
* code organization ([10ba1d8](https://github.com/www-zaq-ai/zaq/commit/10ba1d8e42bcb4c67d832c41c0dc80fa5bcfb091))
* correctly wire ctx in jido telemetry event to broadcast to BO, define clean BO chat ui update events with tool calls ([b90af31](https://github.com/www-zaq-ai/zaq/commit/b90af310bc7a3f3cc3bc1246087f020c21ab0604))
* **e2e:** replace fake NodeRouter with LLMRunner injection to fake only the LLM boundary ([558af04](https://github.com/www-zaq-ai/zaq/commit/558af0473ce3f2bb2f8e3cb6dd7dba7761cf4358))
* extract duplicate function in helper ([ae38a79](https://github.com/www-zaq-ai/zaq/commit/ae38a79a7588d47e5a28d285b84032510130130e))
* fix code duplication and slop ([d9654a5](https://github.com/www-zaq-ai/zaq/commit/d9654a586ba1e5e92a8cb2d724234af6aee37a70))
* fold Jido telemetry handlers into central bridge module ([f7bce06](https://github.com/www-zaq-ai/zaq/commit/f7bce06dd51e097f55cc1e66998ef099969b8ccb))
* implement pr review changes ([11ea528](https://github.com/www-zaq-ai/zaq/commit/11ea528f44e1f126419dff0be22c484a81775a21))
* include some seams to increase code coverage ([ac6efa5](https://github.com/www-zaq-ai/zaq/commit/ac6efa539c38b0a154500dcdc0723d4510e520ce))
* **mix:** remove ex_dna not needed in mix q ([8a09c59](https://github.com/www-zaq-ai/zaq/commit/8a09c596c1dc21eab70e3028e3f21485f0701cd2))
* reduce code duplication ([2c66105](https://github.com/www-zaq-ai/zaq/commit/2c661055378bf9818f8ec9747a37f3968ae59281))
* remove code duplicates and optimize code performance ([0a2684a](https://github.com/www-zaq-ai/zaq/commit/0a2684aa349f49e3da64c2a6a4c2c93b692e2008))
* remove dead code and avoid agent's process recreation on prompt updates ([c163584](https://github.com/www-zaq-ai/zaq/commit/c163584e845dceb571dc34745a7b8675460e167e))
* remove incoming concerns from server_manager, get history from Factory ([f3f8158](https://github.com/www-zaq-ai/zaq/commit/f3f8158aa202d95eb2f7ca99df3b338f7d21aa22))
* **UI:** move revealable secret field into a re-usable UI component ([8517cb9](https://github.com/www-zaq-ai/zaq/commit/8517cb93c298daeeb91324ed086f6e1d1efc30bc))
* update sorting logic and add docs ([a55b272](https://github.com/www-zaq-ai/zaq/commit/a55b2720ed1799c6701ae370846cc509b89e47bd))

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
