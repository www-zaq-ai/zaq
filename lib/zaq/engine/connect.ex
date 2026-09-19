defmodule Zaq.Engine.Connect do
  @moduledoc """
  Engine context for reusable provider credentials and resource-bound grants.

  `change_credential_grant/3` prepares encrypted canonical storage changesets for
  trusted Engine callers. It does not authorize Person management. Legacy grant
  listing and filter-based resolution select only resource-bound rows. Scheduled
  refresh includes canonical grants through the same claimed refresh boundary.

  Canonical mutation delegates use `Mutations` for atomic policy saves and trusted
  credential/owner-bound replacement and cleanup. They return safe DTOs, not schemas.
  Both mutation lanes persist secret-free Oban notifications in the write transaction
  via `MutationEvents`; refresh and token-cache writes share the same persistence.

  Person self-management is the separate backend-only `PersonCredentials` context.
  Its trusted adapter authentication precondition is not satisfied by an event actor
  or raw owner ID. Generic admin/runtime APIs here are not Person transport actions.
  Legacy `issue_grant/1` rejects Person ownership before building a changeset.

  `resolve_credential/3` is privileged runtime-only canonical selection. It returns
  redacted ephemeral generic authentication, never a public event response. Nil
  actors intentionally select org here and do not authorize Person management.

  `PersonLifecycle` owns transactional Person grant transfer, secret erasure and
  OAuth cancellation for Accounts, plus bounded orphan reconciliation. Its dedicated
  maintenance worker consumes independently of deferred mutation notifications.
  """

  import Ecto.Query
  import Zaq.Helpers, only: [blank?: 1]

  alias Ecto.Changeset
  alias Oban.Job
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Connect.{Credential, Grant, MutationEvents, Mutations, OAuth, Refresh}
  alias Zaq.Engine.Connect.GrantRefreshWorker
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Repo
  alias Zaq.System.HttpCredentialProvider
  alias Zaq.System.HttpCredentialProviderRef
  alias Zaq.System.SecretConfig
  alias Zaq.Types.EncryptedString
  alias Zaq.Utils.DateUtils
  alias Zaq.Utils.Map, as: MapUtils

  @secret_fields ~w(client_secret api_key access_token refresh_token private_key)a

  @type mutation_error ::
          Changeset.t()
          | :mutation_event_enqueue_failed
          | :not_found
          | :canonical_grant_requires_owner

  @doc "Privileged runtime-only resolution; never expose as a public Engine action."
  @spec resolve_credential(
          Zaq.Engine.Connect.CredentialResolver.credential_ref(),
          Zaq.Identity.ActorNormalizer.actor(),
          keyword()
        ) :: Zaq.Engine.Connect.CredentialResolver.result()
  defdelegate resolve_credential(credential, trusted_actor, opts \\ []),
    to: Zaq.Engine.Connect.CredentialResolver

  @doc "Trusted secret-free status read for one explicit canonical owner slot."
  @spec get_credential_grant_status(
          Zaq.Engine.Connect.Mutations.credential_ref(),
          Zaq.Engine.Connect.Mutations.owner(),
          keyword()
        ) :: Zaq.Engine.Connect.CredentialStatuses.result()
  defdelegate get_credential_grant_status(credential, owner, opts \\ []),
    to: Zaq.Engine.Connect.CredentialStatuses,
    as: :get

  @doc "Trusted atomic canonical configuration save; global defaults to :keep."
  @spec save_credential_configuration(
          Zaq.Engine.Connect.Mutations.credential_ref() | nil,
          map(),
          Zaq.Engine.Connect.Mutations.global_instruction(),
          keyword()
        ) :: Zaq.Engine.Connect.Mutations.result()
  defdelegate save_credential_configuration(credential, attrs, global \\ :keep, opts \\ []),
    to: Zaq.Engine.Connect.Mutations

  @doc "Trusted complete replacement in an explicit canonical owner slot."
  @spec replace_credential_grant(
          Zaq.Engine.Connect.Mutations.credential_ref(),
          Zaq.Engine.Connect.Mutations.owner(),
          map(),
          keyword()
        ) :: Zaq.Engine.Connect.Mutations.result()
  defdelegate replace_credential_grant(credential, owner, material, opts \\ []),
    to: Zaq.Engine.Connect.Mutations

  @doc "Trusted secret-clearing revocation retaining the canonical owner slot."
  @spec revoke_credential_grant(
          Zaq.Engine.Connect.Mutations.credential_ref(),
          Zaq.Engine.Connect.Mutations.owner()
        ) :: Zaq.Engine.Connect.Mutations.result()
  defdelegate revoke_credential_grant(credential, owner), to: Zaq.Engine.Connect.Mutations

  @doc "Trusted idempotent removal of the canonical owner slot."
  @spec remove_credential_grant(
          Zaq.Engine.Connect.Mutations.credential_ref(),
          Zaq.Engine.Connect.Mutations.owner()
        ) :: Zaq.Engine.Connect.Mutations.result()
  defdelegate remove_credential_grant(credential, owner), to: Zaq.Engine.Connect.Mutations

  @spec list_credentials() :: [Credential.t()]
  def list_credentials do
    Credential
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  @spec get_credential!(integer() | String.t()) :: Credential.t()
  def get_credential!(id), do: Repo.get!(Credential, id)

  @spec fetch_credential(integer() | String.t() | nil) ::
          {:ok, Credential.t()} | {:error, :not_found}
  def fetch_credential(nil), do: {:error, :not_found}

  def fetch_credential(id) do
    case Repo.get(Credential, id) do
      %Credential{} = credential -> {:ok, credential}
      nil -> {:error, :not_found}
    end
  end

  @spec change_credential(Credential.t(), map()) :: Changeset.t()
  def change_credential(%Credential{} = credential, attrs \\ %{}) do
    Credential.changeset(credential, attrs)
  end

  @spec create_credential(map()) :: {:ok, Credential.t()} | {:error, mutation_error()}
  def create_credential(attrs) do
    %Credential{}
    |> Credential.changeset(attrs)
    |> validate_provider_reference()
    |> encrypt_secret_fields(@secret_fields)
    |> MutationEvents.persist("credential_created")
  end

  @spec update_credential(Credential.t(), map()) ::
          {:ok, Credential.t()} | {:error, mutation_error()}
  def update_credential(%Credential{} = credential, attrs) do
    attrs = drop_blank_secret_attrs(attrs, ["client_secret", "api_key", :client_secret, :api_key])

    credential
    |> Credential.changeset(attrs)
    |> validate_provider_reference()
    |> encrypt_secret_fields(@secret_fields)
    |> MutationEvents.persist("credential_updated")
  end

  @spec delete_credential(Credential.t()) :: {:ok, Credential.t()} | {:error, mutation_error()}
  def delete_credential(%Credential{} = credential), do: MutationEvents.delete(credential)

  @spec list_grants(keyword()) :: [Grant.t()]
  def list_grants(opts \\ []) do
    query =
      from(g in Grant,
        where: g.resource_type != "connect_credential",
        order_by: [desc: g.inserted_at]
      )

    query
    |> maybe_filter_by(opts, :credential_id)
    |> maybe_filter_by(opts, :provider)
    |> maybe_filter_by(opts, :resource_type)
    |> maybe_filter_by(opts, :resource_id)
    |> maybe_filter_by(opts, :owner_type)
    |> maybe_filter_by(opts, :owner_id)
    |> maybe_filter_by(opts, :status)
    |> Repo.all()
  end

  @doc "Lists secret-free grant summaries, including canonical credential-bound grants."
  @spec list_grant_summaries(keyword()) :: [map()]
  def list_grant_summaries(opts \\ []) do
    Grant
    |> order_by([g], desc: g.inserted_at)
    |> maybe_filter_by(opts, :credential_id)
    |> maybe_filter_by(opts, :provider)
    |> maybe_filter_by(opts, :resource_type)
    |> maybe_filter_by(opts, :resource_id)
    |> maybe_filter_by(opts, :owner_type)
    |> maybe_filter_by(opts, :owner_id)
    |> maybe_filter_by(opts, :status)
    |> select([g], %{
      id: g.id,
      credential_id: g.credential_id,
      resource_type: g.resource_type,
      resource_id: g.resource_id,
      owner_type: g.owner_type,
      owner_id: g.owner_id,
      request_format: g.request_format,
      status: g.status,
      scopes: g.scopes,
      expires_at: g.expires_at,
      refreshable: not is_nil(g.refresh_token)
    })
    |> Repo.all()
  end

  @doc "Prepares a credential-bound grant storage changeset with strictly encrypted secrets."
  @spec change_credential_grant(Grant.t(), Credential.t(), map()) :: Changeset.t()
  def change_credential_grant(%Grant{} = grant, %Credential{} = credential, attrs) do
    grant
    |> Grant.credential_changeset(credential, attrs)
    |> validate_current_grant_owner()
    |> encrypt_secret_fields(@secret_fields)
  end

  # This checks current storage identity, not caller authentication. Concurrent
  # deletion can still orphan a grant; lifecycle reconciliation is a later slice.
  defp validate_current_grant_owner(%Changeset{valid?: true} = changeset) do
    if Changeset.get_field(changeset, :owner_type) == "person" do
      owner_id = Changeset.get_field(changeset, :owner_id)

      if Repo.exists?(
           from p in Zaq.Accounts.Person, where: p.id == ^owner_id and p.status == "active"
         ),
         do: changeset,
         else: Changeset.add_error(changeset, :owner_id, "must reference a current active Person")
    else
      changeset
    end
  end

  defp validate_current_grant_owner(changeset), do: changeset

  @doc "Legacy org/user issuance only; Person management uses PersonCredentials."
  @spec issue_grant(map()) ::
          {:ok, Grant.t()}
          | {:error, mutation_error() | :provider_mismatch | :person_management_required}
  def issue_grant(%{owner_type: type}) when type in ["person", :person],
    do: {:error, :person_management_required}

  def issue_grant(%{"owner_type" => type}) when type in ["person", :person],
    do: {:error, :person_management_required}

  def issue_grant(attrs) do
    attrs = Map.new(attrs)

    with {:ok, credential} <- fetch_credential(attrs[:credential_id] || attrs["credential_id"]) do
      grant_attrs =
        attrs
        |> enrich_grant_attrs(credential)

      with :ok <- validate_resource_provider(grant_attrs, credential.provider) do
        %Grant{}
        |> Grant.changeset(grant_attrs)
        |> encrypt_secret_fields(@secret_fields)
        |> MutationEvents.persist("grant_created")
      end
    end
  end

  @spec update_grant_token_cache(Grant.t(), map()) :: {:ok, Grant.t()} | {:error, term()}
  def update_grant_token_cache(%Grant{} = grant, token_payload) when is_map(token_payload),
    do: Refresh.cache(grant, &update_grant_tokens(&1, token_payload))

  defp validate_resource_provider(attrs, provider) do
    resource_type = Map.get(attrs, :resource_type) || Map.get(attrs, "resource_type")
    resource_id = Map.get(attrs, :resource_id) || Map.get(attrs, "resource_id")

    case resource_type do
      "data_source" ->
        case Repo.get(ChannelConfig, resource_id) do
          %ChannelConfig{provider: ^provider} -> :ok
          %ChannelConfig{} -> {:error, :provider_mismatch}
          nil -> :ok
        end

      _ ->
        :ok
    end
  end

  defp validate_provider_reference(%Changeset{} = changeset) do
    provider = Changeset.get_field(changeset, :provider)

    case HttpCredentialProviderRef.parse(provider) do
      {:ok, {:static, _provider}} ->
        changeset

      {:ok, {:http, id}} ->
        validate_http_provider_exists(changeset, id)

      {:error, :invalid_http_provider_id} ->
        Changeset.add_error(changeset, :provider, "is not a valid HTTP provider reference")

      {:error, :invalid_provider_ref} ->
        Changeset.add_error(changeset, :provider, "is invalid")
    end
  end

  defp validate_http_provider_exists(changeset, id) do
    case Repo.get(HttpCredentialProvider, id) do
      %HttpCredentialProvider{} ->
        changeset

      nil ->
        Changeset.add_error(changeset, :provider, "does not reference an existing HTTP provider")
    end
  end

  @doc "Legacy resource-grant revocation. Canonical grants require revoke_credential_grant/2 with explicit ownership."
  @spec revoke_grant(Grant.t()) :: {:ok, Grant.t()} | {:error, mutation_error()}
  def revoke_grant(%Grant{resource_type: "connect_credential"}),
    do: {:error, :canonical_grant_requires_owner}

  def revoke_grant(%Grant{} = grant) do
    grant
    |> Grant.changeset(%{status: "revoked"})
    |> MutationEvents.persist("grant_revoked")
  end

  @spec delete_grant(Grant.t()) :: {:ok, Grant.t()} | {:error, mutation_error()}
  # Temporary: this struct-based delete remains for legacy resource-bound BO/event
  # consumers. Remove it once those callers use explicit resource/owner lifecycle APIs.
  # Tracked: zaq-wml
  def delete_grant(%Grant{} = grant), do: MutationEvents.delete(grant)

  @doc "Removes one grant constrained to its credential without exposing its schema or secrets."
  @spec remove_grant_for_credential(integer(), integer()) ::
          {:ok, map() | Grant.t()} | {:error, mutation_error()}
  def remove_grant_for_credential(credential_id, grant_id) do
    case Repo.get_by(Grant, id: grant_id, credential_id: credential_id) do
      %Grant{resource_type: "connect_credential", owner_type: "person", owner_id: owner_id} ->
        remove_credential_grant(credential_id, {:person, owner_id})

      %Grant{resource_type: "connect_credential"} ->
        remove_credential_grant(credential_id, :org)

      %Grant{} = grant ->
        delete_grant(grant)

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Queues refresh for one grant constrained to its credential."
  @spec schedule_grant_refresh(integer(), integer()) ::
          {:ok, Oban.Job.t()} | {:error, Changeset.t() | :not_found}
  def schedule_grant_refresh(credential_id, grant_id) do
    case Repo.get_by(Grant, id: grant_id, credential_id: credential_id) do
      %Grant{} = grant -> schedule_refresh(grant)
      nil -> {:error, :not_found}
    end
  end

  @spec get_active_grant(map()) :: Grant.t() | nil
  def get_active_grant(filters) when is_map(filters) do
    now = DateTime.utc_now()

    Grant
    |> where([g], g.resource_type != "connect_credential")
    |> where([g], g.status == "active")
    |> where([g], is_nil(g.expires_at) or g.expires_at > ^now or g.auth_kind == "jwt_bearer")
    |> maybe_where_credential_id(Map.get(filters, :credential_id))
    |> where([g], g.provider == ^Map.get(filters, :provider))
    |> where([g], g.resource_type == ^Map.get(filters, :resource_type))
    |> where([g], g.resource_id == ^to_string(Map.get(filters, :resource_id)))
    |> where([g], g.owner_type == ^Map.get(filters, :owner_type, "org"))
    |> maybe_where_owner_id(Map.get(filters, :owner_id))
    |> order_by([g], desc: g.inserted_at, desc: g.id)
    |> limit(1)
    |> Repo.one()
  end

  @spec resolve_bearer_token(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve_bearer_token(filters, opts \\ []) when is_map(filters) do
    with %Grant{} = grant <- get_latest_active_grant(filters),
         {:ok, grant} <- prepare_grant_for_use(grant, opts),
         token when not is_nil(token) <- present_token(grant.access_token) do
      {:ok, token}
    else
      nil -> {:error, :missing_grant}
      {:error, _} = error -> error
    end
  end

  @spec expiring_oauth_grants(DateTime.t(), non_neg_integer()) :: [Grant.t()]
  def expiring_oauth_grants(now \\ DateTime.utc_now(), window_seconds \\ 600) do
    threshold = DateTime.add(now, window_seconds, :second)

    Grant
    |> where([g], g.status in ["active", "expired"] and g.auth_kind == "oauth2")
    |> where([g], not is_nil(g.refresh_token))
    |> where([g], not is_nil(g.expires_at) and g.expires_at <= ^threshold)
    |> where([g], is_nil(g.refresh_claim_until) or g.refresh_claim_until <= ^now)
    |> Repo.all()
  end

  @spec schedule_refresh(Grant.t()) :: {:ok, Oban.Job.t()} | {:error, Changeset.t()}
  def schedule_refresh(%Grant{id: id}) do
    %{grant_id: id}
    |> GrantRefreshWorker.new()
    |> Oban.insert()
  end

  @spec next_refresh_jobs_for_grants([Grant.t()]) :: %{integer() => DateTime.t() | nil}
  def next_refresh_jobs_for_grants(grants) when is_list(grants) do
    grant_ids =
      grants
      |> Enum.map(& &1.id)
      |> Enum.reject(&is_nil/1)

    if grant_ids == [] do
      %{}
    else
      now = DateTime.utc_now()

      by_grant_id =
        Job
        |> where([j], j.worker == ^to_string(GrantRefreshWorker))
        |> where([j], j.state in ["scheduled", "available", "retryable"])
        |> where(
          [j],
          fragment("(args->>'grant_id')::bigint = ANY(?)", type(^grant_ids, {:array, :integer}))
        )
        |> where([j], is_nil(j.scheduled_at) or j.scheduled_at >= ^now)
        |> select([j], {fragment("(args->>'grant_id')::bigint"), j.scheduled_at, j.inserted_at})
        |> Repo.all()
        |> Enum.group_by(
          fn {grant_id, _scheduled_at, _inserted_at} -> grant_id end,
          fn {_grant_id, scheduled_at, inserted_at} -> scheduled_at || inserted_at end
        )
        |> Map.new(fn {grant_id, datetimes} ->
          {grant_id, Enum.min_by(datetimes, &DateTime.to_unix/1)}
        end)

      Map.new(grant_ids, fn grant_id -> {grant_id, Map.get(by_grant_id, grant_id)} end)
    end
  end

  @spec refresh_grant(Grant.t(), keyword()) :: {:ok, Grant.t()} | {:error, term()}
  def refresh_grant(%Grant{} = grant, opts \\ []) do
    Refresh.run(grant, &dispatch_refresh/3, &persist_refresh/4, opts)
  end

  @doc """
  Internal runtime API for an already selected grant, without policy selection or fallback.
  Reloads current identity/configuration and refreshes OAuth near expiry. Returns a
  secret-bearing runtime schema, never a management DTO. `:refresh_busy`,
  `:refresh_failed`, and sanitized `:oauth_refresh_failed` tuples are retryable;
  callers must bound retries rather than loop. OAuth failures may include an HTTP
  status and safe provider error code, but never raw provider bodies or messages.
  The canonical resolver supplies an internal `:expected_fingerprint` captured under
  selection locks; cached reads and refresh claims reject a changed raw snapshot.
  """
  @spec prepare_grant_for_use(Grant.t(), keyword()) :: {:ok, Grant.t()} | {:error, term()}
  def prepare_grant_for_use(%Grant{} = grant, opts \\ []) do
    with {:ok, current} <- Refresh.current(grant, opts) do
      maybe_refresh_before_use(current, opts)
    end
  end

  defp persist_refresh(
         %Grant{resource_type: "connect_credential"} = grant,
         credential,
         payload,
         opts
       ) do
    with {:ok, attrs} <- token_update_attrs(grant, payload) do
      Mutations.persist_refreshed_grant(
        grant,
        credential,
        Map.take(attrs, [:access_token, :refresh_token, :expires_at, :metadata]),
        opts
      )
    end
  end

  defp persist_refresh(grant, _credential, payload, opts),
    do: update_grant_tokens(grant, payload, opts)

  defp get_latest_active_grant(filters) do
    Grant
    |> where([g], g.resource_type != "connect_credential")
    |> where([g], g.status == "active")
    |> maybe_where_credential_id(Map.get(filters, :credential_id))
    |> maybe_where_filter(:provider, Map.get(filters, :provider))
    |> maybe_where_filter(:resource_type, Map.get(filters, :resource_type))
    |> maybe_where_filter(:resource_id, to_string(Map.get(filters, :resource_id)))
    |> maybe_where_filter(:owner_type, Map.get(filters, :owner_type, "org"))
    |> maybe_where_owner_id(Map.get(filters, :owner_id))
    |> order_by([g], desc: g.inserted_at, desc: g.id)
    |> limit(1)
    |> Repo.one()
  end

  defp maybe_refresh_before_use(%Grant{} = grant, opts) do
    now = DateUtils.now(opts)
    refresh_window_seconds = Keyword.get(opts, :refresh_window_seconds, 60)

    cond do
      grant.status == "expired" ->
        refresh_grant(grant, opts)

      present_token(grant.access_token) == nil ->
        refresh_grant(grant, opts)

      is_nil(grant.expires_at) ->
        {:ok, grant}

      DateTime.compare(
        grant.expires_at,
        DateTime.add(now, refresh_window_seconds, :second)
      ) == :gt ->
        {:ok, grant}

      true ->
        refresh_grant(grant, opts)
    end
  end

  defp present_token(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp present_token(_), do: nil

  defp maybe_filter_by(query, opts, field) do
    case Keyword.get(opts, field) do
      nil -> query
      value -> where(query, [row], field(row, ^field) == ^value)
    end
  end

  defp maybe_where_filter(query, _field, nil), do: query

  defp maybe_where_filter(query, _field, "nil"), do: query

  defp maybe_where_filter(query, field, value),
    do: where(query, [row], field(row, ^field) == ^value)

  defp maybe_where_owner_id(query, nil), do: where(query, [g], is_nil(g.owner_id))
  defp maybe_where_owner_id(query, owner_id), do: where(query, [g], g.owner_id == ^owner_id)

  defp maybe_where_credential_id(query, nil), do: query

  defp maybe_where_credential_id(query, credential_id) do
    case normalize_credential_id(credential_id) do
      nil -> query
      id -> where(query, [g], g.credential_id == ^id)
    end
  end

  defp normalize_credential_id(id) when is_integer(id), do: id

  defp normalize_credential_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp normalize_credential_id(_), do: nil

  defp dispatch_refresh(%Grant{} = grant, %Credential{} = credential, opts) do
    case OAuth.refresh_token_payload(credential, grant, opts) do
      {:ok, _token_payload} = ok -> ok
      {:error, _reason} = error -> error
      :fallback -> dispatch_channels_refresh(grant, credential, opts)
    end
  end

  defp dispatch_channels_refresh(%Grant{} = grant, %Credential{} = credential, opts) do
    params = %{
      "credential_id" => credential.id,
      "client_id" => credential.client_id,
      "client_secret" => credential.client_secret,
      "refresh_token" => grant.refresh_token,
      "scope" => Enum.join(credential.scopes || [], " ")
    }

    event =
      Event.new(
        %{provider: grant.provider, params: params},
        :channels,
        opts:
          [
            action: :data_source_oauth_refresh_token,
            confidential: true,
            oauth_credentials:
              if(grant.resource_type == "connect_credential", do: :explicit, else: :legacy)
          ]
          |> maybe_put_config(opts)
      )

    case NodeRouter.dispatch(event).response do
      {:ok, token_payload} when is_map(token_payload) -> {:ok, token_payload}
      {:error, _} = error -> error
      other -> {:error, {:invalid_refresh_response, other}}
    end
  end

  defp maybe_put_config(event_opts, opts) do
    if Keyword.has_key?(opts, :config),
      do: Keyword.put(event_opts, :config, Keyword.fetch!(opts, :config)),
      else: event_opts
  end

  defp update_grant_tokens(%Grant{} = grant, token_payload, opts \\ []) do
    with {:ok, attrs} <- token_update_attrs(grant, token_payload) do
      grant
      |> Grant.changeset(Map.put(attrs, :status, "active"))
      |> encrypt_token_changes(opts)
      |> MutationEvents.persist("grant_tokens_updated")
      |> case do
        {:ok, updated_grant} -> {:ok, Repo.reload!(updated_grant)}
        {:error, _} = error -> error
      end
    end
  end

  defp encrypt_token_changes(changeset, opts) do
    Enum.reduce([:access_token, :refresh_token], changeset, fn field, acc ->
      case Changeset.get_change(acc, field) do
        value when is_binary(value) and value != "" ->
          encrypt_token_change(acc, field, value, opts)

        _ ->
          acc
      end
    end)
  end

  defp encrypt_token_change(changeset, field, value, opts) do
    case SecretConfig.encrypt(value, opts) do
      {:ok, ciphertext} -> Changeset.force_change(changeset, field, ciphertext)
      {:error, reason} -> Changeset.add_error(changeset, field, encryption_error_message(reason))
    end
  end

  defp token_update_attrs(%Grant{auth_kind: "oauth2"} = grant, token_payload) do
    access_token = payload_get(token_payload, :access_token)
    refresh_token = payload_get(token_payload, :refresh_token) || grant.refresh_token
    expires_at = payload_get(token_payload, :expires_at)

    cond do
      blank?(access_token) ->
        {:error, {:invalid_token_payload, :missing_access_token}}

      blank?(refresh_token) ->
        {:error, {:invalid_token_payload, :missing_refresh_token}}

      is_nil(expires_at) ->
        {:error, {:invalid_token_payload, :missing_expires_at}}

      true ->
        attrs = %{
          access_token: access_token,
          refresh_token: refresh_token,
          expires_at: expires_at,
          scopes: payload_get(token_payload, :scopes) || grant.scopes || []
        }

        {:ok, maybe_put_token_metadata(attrs, grant, token_payload)}
    end
  end

  defp token_update_attrs(%Grant{auth_kind: "jwt_bearer"} = grant, token_payload) do
    access_token = payload_get(token_payload, :access_token)
    expires_at = payload_get(token_payload, :expires_at)

    cond do
      blank?(access_token) ->
        {:error, {:invalid_token_payload, :missing_access_token}}

      is_nil(expires_at) ->
        {:error, {:invalid_token_payload, :missing_expires_at}}

      true ->
        # JWT bearer mint responses generally do not carry scope information.
        # Keep existing grant scopes unchanged when refreshing token cache.
        {:ok,
         %{
           access_token: access_token,
           refresh_token: payload_get(token_payload, :refresh_token) || grant.refresh_token,
           expires_at: expires_at
         }}
    end
  end

  defp token_update_attrs(%Grant{}, _token_payload),
    do: {:error, {:invalid_token_payload, :unsupported_auth_kind}}

  defp maybe_put_token_metadata(attrs, %Grant{} = grant, token_payload) do
    case payload_get(token_payload, :metadata) do
      metadata when is_map(metadata) ->
        Map.put(attrs, :metadata, Map.merge(grant.metadata || %{}, metadata))

      _ ->
        attrs
    end
  end

  defp payload_get(payload, key) when is_map(payload),
    do: Map.get(payload, key) || Map.get(payload, Atom.to_string(key))

  defp enrich_grant_attrs(attrs, %Credential{} = credential) do
    auth_kind = Map.get(attrs, :auth_kind) || Map.get(attrs, "auth_kind") || credential.auth_kind
    resource_id = Map.get(attrs, :resource_id) || Map.get(attrs, "resource_id")

    normalized_resource_id = if is_nil(resource_id), do: nil, else: to_string(resource_id)

    attrs
    |> Map.put(:provider, credential.provider)
    |> Map.put(:auth_kind, auth_kind)
    |> Map.put(:request_format, credential.request_format)
    |> Map.put_new(:status, "active")
    |> Map.put(:resource_id, normalized_resource_id)
    |> maybe_copy_credential_scopes(credential, auth_kind)
    |> maybe_copy_credential_api_key(credential, auth_kind)
    |> maybe_copy_credential_jwt_fields(credential, auth_kind)
  end

  defp maybe_copy_credential_scopes(attrs, credential, "jwt_bearer") do
    case Map.get(attrs, :scopes) || Map.get(attrs, "scopes") do
      nil -> Map.put(attrs, :scopes, credential.scopes || [])
      [] -> Map.put(attrs, :scopes, credential.scopes || [])
      _ -> attrs
    end
  end

  defp maybe_copy_credential_scopes(attrs, _credential, _), do: attrs

  defp maybe_copy_credential_api_key(attrs, credential, "api_key") do
    case Map.get(attrs, :api_key) || Map.get(attrs, "api_key") do
      nil -> Map.put(attrs, :api_key, credential.api_key)
      _ -> attrs
    end
  end

  defp maybe_copy_credential_api_key(attrs, _credential, _), do: attrs

  defp maybe_copy_credential_jwt_fields(attrs, credential, "jwt_bearer") do
    attrs
    |> maybe_put_missing_attr(:issuer, credential.issuer)
    |> maybe_put_missing_attr(:private_key, credential.private_key)
    |> maybe_put_missing_attr(:key_id, credential.key_id)
    |> maybe_put_missing_attr(:subject, MapUtils.metadata_subject(credential.metadata))
  end

  defp maybe_copy_credential_jwt_fields(attrs, _credential, _), do: attrs

  defp maybe_put_missing_attr(attrs, _key, value) when value in [nil, ""], do: attrs

  defp maybe_put_missing_attr(attrs, key, value) do
    case Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      nil -> Map.put(attrs, key, value)
      "" -> Map.put(attrs, key, value)
      _ -> attrs
    end
  end

  defp drop_blank_secret_attrs(attrs, keys) do
    Enum.reduce(keys, attrs, fn key, acc ->
      if Map.get(acc, key) == "" do
        Map.delete(acc, key)
      else
        acc
      end
    end)
  end

  defp encrypt_secret_fields(%Changeset{} = changeset, fields) do
    Enum.reduce(fields, changeset, &encrypt_secret_field(&2, &1))
  end

  defp encrypt_secret_field(%Changeset{} = changeset, field) do
    case Changeset.get_change(changeset, field) do
      nil -> changeset
      "" -> changeset
      value when is_binary(value) -> maybe_encrypt_secret(changeset, field, value)
      _ -> changeset
    end
  end

  defp maybe_encrypt_secret(changeset, field, value) do
    if EncryptedString.encrypted?(value) do
      changeset
    else
      case EncryptedString.encrypt(value) do
        {:ok, encrypted} ->
          Changeset.put_change(changeset, field, encrypted)

        {:error, reason} ->
          Changeset.add_error(changeset, field, encryption_error_message(reason))
      end
    end
  end

  defp encryption_error_message(:missing_encryption_key),
    do: "could not be encrypted: missing SYSTEM_CONFIG_ENCRYPTION_KEY"

  defp encryption_error_message(:invalid_encryption_key),
    do: "could not be encrypted: invalid SYSTEM_CONFIG_ENCRYPTION_KEY"

  defp encryption_error_message(_), do: "could not be encrypted"
end
