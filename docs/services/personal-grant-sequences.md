# Personal Grant Sequences

These diagrams describe the current Person-scoped Connect implementation. Participants
are code modules or external systems; arrows name the relevant public or coordinating
function. The diagrams deliberately expose transaction and network boundaries so the
module split can be reviewed.

There is currently no production People UI or Person-facing HTTP route for creating a
personal grant. The first hop in the creation diagrams is therefore the supported
confidential Engine event boundary rather than an invented screen. OAuth callback
handling does have a production controller route.

## 1. A Person adds a personal grant

### 1A. API key

```mermaid
sequenceDiagram
    autonumber
    actor Caller as Authenticated caller
    participant NR as Zaq.NodeRouter
    participant API as Zaq.Engine.API
    participant GW as Zaq.Engine.PeopleAuthGateway
    participant PC as Zaq.Engine.PeopleCredentials
    participant Auth as Zaq.Accounts.PeopleAuth
    participant Perm as Zaq.Accounts.PeoplePermissions
    participant Own as Zaq.Engine.Connect.PersonCredentials
    participant Mut as Zaq.Engine.Connect.Mutations
    participant Sec as Zaq.System.SecretConfig
    participant Events as Zaq.Engine.Connect.MutationEvents
    participant DB as Zaq.Repo / PostgreSQL
    participant Oban as Oban

    Caller->>NR: dispatch confidential Event<br>action=:people_auth, op=:put_self_credential
    NR->>API: handle_event(event, :people_auth, nil)<br>(local call or remote RPC)
    API->>GW: dispatch(request, opts)
    GW->>PC: dispatch(:put_self_credential, bearer, payload, opts)

    rect rgb(245, 245, 245)
        Note over PC,DB: One database transaction, any error rolls back the grant and event job
        PC->>Auth: authenticate(bearer, opts)
        Auth->>DB: lock/reload session and literal Person
        DB-->>Auth: active Person + current session
        Auth-->>PC: authenticated Person
        PC->>Perm: allowed?(person, [:access_profile, :manage_credentials])
        Perm->>DB: load Everyone/team permission grants
        DB-->>Perm: effective capabilities
        Perm-->>PC: true
        PC->>Own: put_own_authentication(person, credential_id, material, opts)
        Own->>DB: lock credential, reload literal active Person<br>validate personal policy and API-key auth kind
        Note over Own: owner_id is derived from the authenticated Person,<br>the request cannot select another owner
        Own->>Mut: replace_credential_grant(credential, {:person, person.id}, attrs, opts)
        Mut->>DB: lock existing/absent canonical owner slot
        Mut->>Sec: encrypt(api_key)
        Sec-->>Mut: encrypted material
        Mut->>Events: persist(grant changeset, "grant_replaced")
        Events->>DB: insert/update canonical grant
        Events->>Oban: insert MutationEventWorker job
        DB-->>PC: %{credential_id: id, status: "active"}
    end

    PC-->>GW: safe status DTO
    GW-->>API: {:ok, DTO}
    API-->>NR: {:ok, DTO}
    NR-->>Caller: {:ok, DTO}

    Note over Events,Oban: After commit the consumed notification job fans out to all<br>discovered Agent nodes and retries unless every local ServerManager acknowledges fencing.
```

API-key submission does not call the provider. Validation is structural and policy-based;
it is not proof that the key works remotely.

### 1B. OAuth2 grant

```mermaid
sequenceDiagram
    autonumber
    actor Person
    participant Caller as Supported authenticated caller
    participant NR as Zaq.NodeRouter
    participant API as Zaq.Engine.API
    participant GW as Zaq.Engine.PeopleAuthGateway
    participant PC as Zaq.Engine.PeopleCredentials
    participant Auth as Zaq.Accounts.PeopleAuth
    participant Perm as Zaq.Accounts.PeoplePermissions
    participant Own as Zaq.Engine.Connect.PersonCredentials
    participant Attempts as Zaq.Engine.Connect.OAuthAttempts
    participant OAuth as Zaq.Engine.Connect.OAuth
    participant ChAPI as Zaq.Channels.API
    participant Bridge as Zaq.Channels.DataSourceBridge
    participant Adapter as Zaq.Channels.JidoConnectBridge
    participant Provider as OAuth2 provider
    participant Callback as ZaqWeb.ChannelsController
    participant Mut as Zaq.Engine.Connect.Mutations
    participant Sec as Zaq.System.SecretConfig
    participant Events as Zaq.Engine.Connect.MutationEvents
    participant DB as Zaq.Repo / PostgreSQL
    participant Oban as Oban

    Person->>Caller: Start or reconnect credential
    Caller->>NR: confidential :people_auth event<br>op=:start_self_credential_oauth<br>or :reconnect_self_credential_oauth
    NR->>API: handle_event(event, :people_auth, nil)
    API->>GW: dispatch(request, opts)
    GW->>PC: dispatch(oauth_op, bearer, payload, opts)

    rect rgb(245, 245, 245)
        Note over PC,DB: Preparation transaction
        PC->>Auth: authenticate(bearer, opts)
        Auth->>DB: lock/reload session and literal active Person
        PC->>Perm: allowed?(person, [:access_profile, :manage_credentials])
        Perm->>DB: load effective permissions
        PC->>Own: prepare_oauth(person, session_id, credential_id, opts)
        Own->>Attempts: prepare_person(...)
        Attempts->>Sec: encrypt PKCE verifier
        Attempts->>DB: lock credential, validate policy/configuration<br>insert session-bound one-use attempt
        Note over Attempts,DB: Attempt stores encrypted PKCE verifier, configuration fingerprint,<br>server redirect, expiry and session ID, never the bearer token.
    end

    PC->>OAuth: authorize_attempt(credential, signed_state, binding, opts)
    alt Configured authorization URL
        OAuth->>OAuth: build URL from canonical configuration
    else Provider catalog lookup
        OAuth->>NR: confidential Channels OAuth action
        NR->>ChAPI: handle_event(...)
        ChAPI->>Bridge: oauth_authorize_url(provider, explicit_context)
        Bridge->>Adapter: oauth_authorize_url(...)
        Adapter-->>OAuth: authorize URL using explicit client/redirect/scopes + PKCE
    end
    OAuth-->>Caller: %{authorize_url: url}
    Caller-->>Person: Redirect to provider
    Person->>Provider: Authorize
    Provider->>Callback: GET /channels/oauth2/:provider/redirect<br>code + signed attempt state

    Callback->>NR: confidential Engine :invoke
    NR->>API: invoke OAuth.finalize_callback/2
    API->>OAuth: finalize_callback(provider, params)
    OAuth->>Attempts: finalize_callback(provider, params, opts)

    rect rgb(245, 245, 245)
        Note over Attempts,DB: Claim transaction commits before network I/O
        Attempts->>DB: verify signed state, lock and claim unused attempt,<br>clear persisted PKCE/candidate material
    end
    rect rgb(245, 245, 245)
        Note over Attempts,DB: Pre-exchange validation transaction
        Attempts->>DB: recheck attempt, deadline, provider,<br>credential fingerprint and Person eligibility
    end

    Attempts->>OAuth: exchange_attempt(credential, code, binding, opts)
    opt Provider token-endpoint metadata is required
        OAuth->>NR: confidential Channels endpoint lookup
        NR->>ChAPI: handle_event(...)
        ChAPI->>Bridge: oauth_token_endpoint(provider, context)
        Bridge->>Adapter: oauth_token_endpoint(provider)
        Adapter-->>OAuth: token endpoint metadata
    end
    OAuth->>Provider: POST authorization code + bound PKCE verifier
    Provider-->>OAuth: access token, refresh token, expiry
    OAuth-->>Attempts: normalized token payload

    rect rgb(245, 245, 245)
        Note over Attempts,DB: Completion transaction
        Attempts->>Auth: revalidate_session(session_id, person_id, opts)
        Auth->>DB: lock/reload current session and literal active Person
        Attempts->>Perm: allowed?(person, [:access_profile, :manage_credentials])
        Attempts->>DB: recheck attempt, deadline, fingerprint and configuration
        Attempts->>Mut: replace_credential_grant(..., OAuth token material, opts)
        Mut->>Sec: encrypt token material
        Mut->>Events: persist(grant changeset, "grant_replaced")
        Events->>DB: replace canonical Person slot
        Events->>Oban: enqueue mutation event atomically
    end

    Attempts-->>OAuth: %{credential_id: id, status: "active"}
    OAuth-->>Callback: safe result
    Callback-->>Person: status-only callback HTML

    Note over Attempts,Provider: A failed exchange consumes the one-use attempt.<br>A failed reconnect leaves the previous grant unchanged.
```

The important split is that Channels supplies authorization/provider metadata while
Engine owns the canonical token POST and grant persistence. No provider network call is
made while a database transaction is open.

## 2. A personal OAuth2 token is refreshed

```mermaid
sequenceDiagram
    autonumber
    participant Cron as Oban DynamicCron
    participant Jobs as Oban
    participant Sched as Zaq.Engine.Connect.GrantRefreshSchedulerWorker
    participant Worker as Zaq.Engine.Connect.GrantRefreshWorker
    participant Resolver as Zaq.Engine.Connect.CredentialResolver
    participant Connect as Zaq.Engine.Connect
    participant Refresh as Zaq.Engine.Connect.Refresh
    participant Snap as Zaq.Engine.Connect.Snapshot
    participant OAuth as Zaq.Engine.Connect.OAuth
    participant NR as Zaq.NodeRouter
    participant ChAPI as Zaq.Channels.API
    participant Bridge as Zaq.Channels.DataSourceBridge
    participant Adapter as Zaq.Channels.JidoConnectBridge
    participant Provider as OAuth2 provider
    participant Mut as Zaq.Engine.Connect.Mutations
    participant Sec as Zaq.System.SecretConfig
    participant Events as Zaq.Engine.Connect.MutationEvents
    participant DB as Zaq.Repo / PostgreSQL

    alt Scheduled refresh
        Cron->>Sched: perform(job) every five minutes
        Sched->>Connect: expiring_oauth_grants(now, window)
        Connect->>DB: select refreshable grants
        loop each candidate
            Sched->>Connect: schedule_refresh(grant_id)
            Connect->>Jobs: enqueue GrantRefreshWorker job
        end
        Jobs->>Worker: perform(job)
        Worker->>Connect: refresh_grant(grant_id, opts)
    else On-demand use
        Resolver->>DB: select_credential(reference, person)<br>lock and capture grant/config fingerprints
        Resolver->>Connect: prepare_grant_for_use(selected_grant, opts)
        Connect->>Refresh: current(grant, opts)
        Note over Resolver,Refresh: Refresh occurs when expired, missing an access token,<br>or within the default 60-second refresh window.
    end

    Connect->>Refresh: run(grant, dispatch_fun, persist_fun, opts)
    rect rgb(245, 245, 245)
        Note over Refresh,DB: Claim transaction
        Refresh->>DB: lock credential then grant
        Refresh->>Snap: grant_with_credential(grant.id)
        Snap->>DB: capture raw grant/configuration fingerprints
        Refresh->>DB: persist UUID claim with 120-second lease
    end
    rect rgb(245, 245, 245)
        Note over Refresh,DB: Separate verification transaction
        Refresh->>DB: re-lock and recheck status, literal active Person,<br>configuration and expected snapshot
    end

    Refresh->>Connect: dispatch_refresh(credential, grant, opts)
    Connect->>OAuth: refresh_token_payload(credential, grant, opts)
    alt Canonical credential has explicit token_url
        OAuth->>OAuth: use configured endpoint
    else Endpoint comes from provider catalog
        OAuth->>NR: confidential Channels OAuth endpoint action
        NR->>ChAPI: handle_event(...)
        ChAPI->>Bridge: oauth_token_endpoint(provider, context)
        Bridge->>Adapter: oauth_token_endpoint(provider)
        Adapter-->>OAuth: endpoint metadata
    end
    OAuth->>Provider: POST refresh_token grant<br>(outside all DB transactions)
    Provider-->>OAuth: rotated access token, optional refresh token, expiry
    OAuth-->>Refresh: normalized payload

    rect rgb(245, 245, 245)
        Note over Refresh,DB: Finish transaction
        Refresh->>DB: re-lock, verify lease and unchanged raw snapshots
        Refresh->>Connect: persist_refresh(grant, payload, claim, opts)
        Connect->>Mut: persist_refreshed_grant(...)
        Mut->>Sec: encrypt refreshed token material
        Mut->>Events: persist(grant changeset, "grant_tokens_updated")
        Events->>DB: update tokens and clear lease
        Events->>Jobs: enqueue notification atomically
    end

    opt On-demand resolution
        Refresh-->>Resolver: refreshed runtime grant
        Resolver->>DB: final transaction revalidates Person,<br>pinned selection and configuration
        Resolver-->>Resolver: return resolved authentication
    end

    Note over Refresh,DB: A stale or reclaimed lease rejects late provider results.<br>Provider failure retains the lease as a short cooldown, no fallback occurs.
```

The scheduler and resolver converge on one refresh protocol. The resolver adds selection
checks before and after refresh; the scheduled path refreshes the grant directly.

## 3. A Person with personal grants is merged

```mermaid
sequenceDiagram
    autonumber
    actor Admin as BO administrator
    participant Live as ZaqWeb.Live.BO.System.PeopleLive
    participant ED as ZaqWeb.Live.BO.EngineDispatch
    participant NR as Zaq.NodeRouter
    participant API as Zaq.Engine.API
    participant GW as Zaq.Engine.PeopleGateway
    participant People as Zaq.Accounts.People
    participant Merger as Zaq.Accounts.PersonMerger
    participant Auth as Zaq.Accounts.PeopleAuth
    participant Life as Zaq.Engine.Connect.PersonLifecycle
    participant Grant as Zaq.Engine.Connect.Grant
    participant Events as Zaq.Engine.Connect.MutationEvents
    participant DB as Zaq.Repo / PostgreSQL
    participant Oban as Oban

    Admin->>Live: confirm_merge(survivor_id, loser_ids)
    Live->>ED: dispatch people command
    ED->>NR: Event action=:people_command
    NR->>API: handle_event(event, :people_command, nil)
    API->>GW: dispatch(:merge, params)
    GW->>People: merge_persons(survivor, losers, attrs)
    People->>Merger: merge(survivor, losers, attrs)

    rect rgb(245, 245, 245)
        Note over Merger,DB: One Accounts transaction covers identity, grants, attempts and event jobs
        Merger->>DB: acquire identity advisory lock,<br>lock participant and relationship rows
        Merger->>Auth: invalidate_challenges(participant IDs)
        Auth->>DB: invalidate pending challenges
        Merger->>Auth: revoke_all_sessions(participant IDs)
        Auth->>DB: revoke sessions for survivor and losers
        Merger->>DB: apply relationship mutations

        Merger->>Life: merge_people(survivor_id, loser_ids)
        Note over Merger,Life: This is an in-process cross-domain call so Connect writes<br>remain in the same Repo transaction, it is not NodeRouter dispatch.
        Life->>DB: lock credential IDs, then canonical grants,<br>in deterministic ascending order

        loop each credential represented by participants
            alt Survivor already has a slot
                Life->>DB: delete every loser slot and encrypted material
                Life->>Events: persist grant_deleted for loser dependencies
                Life->>Events: persist grant_replaced for unchanged survivor dependency
            else Survivor has no slot
                Life->>Grant: transfer_owner_changeset(lowest loser grant, survivor_id)
                Grant-->>Life: ownership-only changeset
                Life->>DB: update winning row owner, delete remaining loser rows
                Life->>Events: persist old-owner grant_deleted<br>and new-owner grant_created
            end
        end

        Life->>DB: delete OAuth attempts for survivor and every loser
        Events->>Oban: insert secret-free mutation jobs
        Life-->>Merger: :ok
        Merger->>People: delete_merge_loser(loser IDs)
        People->>DB: delete loser People
        Merger->>DB: apply survivor merge result
    end

    Merger-->>People: merged Person
    People-->>GW: result
    GW-->>Live: result

    Note over Life,DB: A survivor slot wins regardless of active/revoked/expired status.<br>Transferred ciphertext is not loaded, decrypted or re-encrypted.
    Note over Events,Oban: Event jobs commit atomically with the merge, then acknowledged<br>Agent-node fanout invalidates matching Person/credential runtimes.
```

All in-flight OAuth attempts for every original participant are cancelled rather than
rebound. Consequently, even a callback already performing provider HTTP cannot save after
the lifecycle transaction removes its persisted attempt.

## 4. A Person is removed

```mermaid
sequenceDiagram
    autonumber
    actor Admin as BO administrator
    participant Live as ZaqWeb.Live.BO.System.PeopleLive
    participant ED as ZaqWeb.Live.BO.EngineDispatch
    participant NR as Zaq.NodeRouter
    participant API as Zaq.Engine.API
    participant GW as Zaq.Engine.PeopleGateway
    participant People as Zaq.Accounts.People
    participant Merger as Zaq.Accounts.PersonMerger
    participant Life as Zaq.Engine.Connect.PersonLifecycle
    participant Events as Zaq.Engine.Connect.MutationEvents
    participant DB as Zaq.Repo / PostgreSQL
    participant Oban as Oban
    participant Reconcile as Zaq.Engine.Connect.SecretReconciliationWorker

    Admin->>Live: delete(person_id) or confirm_bulk_delete(ids)
    Live->>ED: dispatch people command
    ED->>NR: Event action=:people_command
    NR->>API: handle_event(event, :people_command, nil)
    API->>GW: dispatch(:delete or :bulk_delete, params)
    alt Single deletion
        GW->>People: delete_person(person)
    else Bulk deletion
        GW->>People: bulk_delete_people(ids)
    end

    People->>Merger: transaction(delete operation)
    rect rgb(245, 245, 245)
        Note over Merger,DB: One transaction, a bulk failure rolls back the entire group
        Merger->>DB: acquire identity advisory lock and Person locks
        Merger->>Life: delete_people(person_ids)
        Note over Merger,Life: Direct in-process call preserves the shared Repo transaction.
        Life->>DB: lock credential IDs then grant and attempt rows
        loop each personal grant
            Life->>Events: persist grant_deleted dependency
            Life->>DB: delete complete grant row and encrypted material
        end
        Life->>DB: delete all Person-owned OAuth attempts
        Events->>Oban: insert mutation jobs
        Life-->>Merger: :ok
        Merger->>People: protected Person deletion
        People->>DB: delete Person rows
        Note over People,DB: Authentication sessions/challenges cascade with Person deletion.
    end

    People-->>GW: deleted Person or bulk summary
    GW-->>Live: result

    opt Eventual repair for accepted concurrent or historical orphans
        Oban->>Reconcile: scheduled every five minutes
        Reconcile->>Life: reconcile(limit: 100)
        Life->>DB: keyset-scan, lock, recheck and delete orphan grants<br>and expired/orphan OAuth attempts
    end

    Note over Life,DB: Reconciliation is a fallback, not the normal deletion mechanism,<br>normal grant-secret deletion is synchronous and transactional.
```

## Boundary assessment

| Boundary | Assessment |
| --- | --- |
| `NodeRouter` → `Engine.API` → fixed gateway | Sound. Cross-role routing and operation allowlisting remain outside credential-domain code. Confidential routing suppresses secret-bearing workflow broadcasts. |
| `PeopleAuthGateway` → `PeopleCredentials` | Sound. The gateway is a narrow transport dispatcher; `PeopleCredentials` owns the authenticated use case and returns fixed safe DTOs/errors. |
| `PeopleCredentials` → Accounts auth/permissions + Connect domain | Sound application-service split. Authentication and authorization happen before the Person is converted into a domain argument, while ownership is always server-derived. |
| `PersonCredentials` → `Mutations` | Sound. Person eligibility and ownership policy are separate from the canonical lock/encrypt/write/event transaction used by other trusted callers. |
| `OAuthAttempts` → `OAuth` | Sound security boundary, though `OAuthAttempts` is intentionally a substantial coordinator. One-use state and repeated database validation surround provider I/O without holding locks over the network. |
| `OAuth` → Channels modules | Mostly sound but asymmetric. Channels resolves provider authorization/endpoint behavior; Engine performs canonical exchange/refresh HTTP. The split avoids ambient provider credentials, but should remain explicit because “Channels OAuth” does not mean Channels owns token transport. |
| `CredentialResolver` → `Refresh` → `Mutations` | Sound. Selection, lease/snapshot protocol, provider transport and persistence are separately testable; final resolver revalidation prevents a refreshed stale selection from being returned. |
| `PersonMerger`/`People` → `PersonLifecycle` | Deliberate but architecturally sharp. Accounts depends directly on an Engine Connect lifecycle module. This preserves one database transaction and prevents identity deletion from racing secret cleanup; replacing it with `NodeRouter` would break that atomicity. If the dependency direction becomes problematic, move orchestration to a higher in-process lifecycle coordinator rather than introducing RPC. |
| `MutationEvents` → Oban worker → Agent fanout | Sound eventual invalidation boundary: domain writes and outbox jobs commit together; the worker requires acknowledgments from every discovered Agent node after synchronous local fencing. Partitions and undiscovered owners remain the explicit #775 infrastructure scope. |
| Production Person caller → credential gateway | Incomplete integration rather than a bad internal split. The authenticated backend boundary exists, but no Person-facing start/write route or UI currently invokes it. |

## Source entry points

- [`lib/zaq/engine/people_auth_gateway.ex`](../../lib/zaq/engine/people_auth_gateway.ex)
- [`lib/zaq/engine/people_credentials.ex`](../../lib/zaq/engine/people_credentials.ex)
- [`lib/zaq/engine/connect/person_credentials.ex`](../../lib/zaq/engine/connect/person_credentials.ex)
- [`lib/zaq/engine/connect/oauth_attempts.ex`](../../lib/zaq/engine/connect/oauth_attempts.ex)
- [`lib/zaq/engine/connect/refresh.ex`](../../lib/zaq/engine/connect/refresh.ex)
- [`lib/zaq/engine/connect/credential_resolver.ex`](../../lib/zaq/engine/connect/credential_resolver.ex)
- [`lib/zaq/engine/connect/person_lifecycle.ex`](../../lib/zaq/engine/connect/person_lifecycle.ex)
- [`lib/zaq/accounts/person_merger.ex`](../../lib/zaq/accounts/person_merger.ex)
- [`lib/zaq/accounts/people.ex`](../../lib/zaq/accounts/people.ex)
