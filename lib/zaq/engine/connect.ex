defmodule Zaq.Engine.Connect do
  @moduledoc "Engine context for reusable provider credentials and resource-bound grants."

  import Ecto.Query
  import Zaq.Helpers, only: [blank?: 1]

  alias Ecto.Changeset
  alias Oban.Job
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Connect.{Credential, Grant}
  alias Zaq.Engine.Connect.GrantRefreshWorker
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Repo
  alias Zaq.Types.EncryptedString
  alias Zaq.Utils.Map, as: MapUtils

  @secret_fields ~w(client_secret api_key access_token refresh_token private_key)a

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

  @spec create_credential(map()) :: {:ok, Credential.t()} | {:error, Changeset.t()}
  def create_credential(attrs) do
    %Credential{}
    |> Credential.changeset(attrs)
    |> encrypt_secret_fields(@secret_fields)
    |> Repo.insert()
  end

  @spec update_credential(Credential.t(), map()) ::
          {:ok, Credential.t()} | {:error, Changeset.t()}
  def update_credential(%Credential{} = credential, attrs) do
    attrs = drop_blank_secret_attrs(attrs, ["client_secret", "api_key", :client_secret, :api_key])

    credential
    |> Credential.changeset(attrs)
    |> encrypt_secret_fields(@secret_fields)
    |> Repo.update()
  end

  @spec delete_credential(Credential.t()) :: {:ok, Credential.t()} | {:error, Changeset.t()}
  def delete_credential(%Credential{} = credential), do: Repo.delete(credential)

  @spec list_grants(keyword()) :: [Grant.t()]
  def list_grants(opts \\ []) do
    query = from(g in Grant, order_by: [desc: g.inserted_at])

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

  @spec issue_grant(map()) :: {:ok, Grant.t()} | {:error, Changeset.t()}
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
        |> Repo.insert()
      end
    end
  end

  @spec update_grant_token_cache(Grant.t(), map()) :: {:ok, Grant.t()} | {:error, term()}
  def update_grant_token_cache(%Grant{} = grant, token_payload) when is_map(token_payload),
    do: update_grant_tokens(grant, token_payload)

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

  @spec revoke_grant(Grant.t()) :: {:ok, Grant.t()} | {:error, Changeset.t()}
  def revoke_grant(%Grant{} = grant) do
    grant
    |> Grant.changeset(%{status: "revoked"})
    |> Repo.update()
  end

  @spec delete_grant(Grant.t()) :: {:ok, Grant.t()} | {:error, Changeset.t()}
  def delete_grant(%Grant{} = grant), do: Repo.delete(grant)

  @spec get_active_grant(map()) :: Grant.t() | nil
  def get_active_grant(filters) when is_map(filters) do
    now = DateTime.utc_now()

    Grant
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

  @spec expiring_oauth_grants(DateTime.t(), non_neg_integer()) :: [Grant.t()]
  def expiring_oauth_grants(now \\ DateTime.utc_now(), window_seconds \\ 600) do
    threshold = DateTime.add(now, window_seconds, :second)

    Grant
    |> where([g], g.status == "active" and g.auth_kind == "oauth2")
    |> where([g], not is_nil(g.refresh_token))
    |> where([g], not is_nil(g.expires_at) and g.expires_at <= ^threshold)
    |> Repo.all()
  end

  @spec schedule_refresh(Grant.t()) :: {:ok, Oban.Job.t()} | {:error, Changeset.t()}
  def schedule_refresh(%Grant{id: id}) do
    %{grant_id: id}
    |> Job.new(worker: to_string(GrantRefreshWorker), queue: :channels)
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

  @spec refresh_grant(Grant.t()) :: {:ok, Grant.t()} | {:error, term()}
  def refresh_grant(%Grant{} = grant) do
    with {:ok, credential} <- fetch_credential(grant.credential_id),
         {:ok, token_payload} <- dispatch_refresh(grant, credential) do
      update_grant_tokens(grant, token_payload)
    end
  end

  defp maybe_filter_by(query, opts, field) do
    case Keyword.get(opts, field) do
      nil -> query
      value -> where(query, [row], field(row, ^field) == ^value)
    end
  end

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

  defp dispatch_refresh(%Grant{} = grant, %Credential{} = credential) do
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
        opts: [action: :data_source_oauth_refresh_token]
      )

    case NodeRouter.dispatch(event).response do
      {:ok, token_payload} when is_map(token_payload) -> {:ok, token_payload}
      {:error, _} = error -> error
      other -> {:error, {:invalid_refresh_response, other}}
    end
  end

  defp update_grant_tokens(%Grant{} = grant, token_payload) do
    with {:ok, attrs} <- token_update_attrs(grant, token_payload) do
      grant
      |> Grant.changeset(attrs)
      |> encrypt_secret_fields(@secret_fields)
      |> Repo.update()
      |> case do
        {:ok, updated_grant} -> {:ok, Repo.reload!(updated_grant)}
        {:error, _} = error -> error
      end
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
        {:ok,
         %{
           access_token: access_token,
           refresh_token: refresh_token,
           expires_at: expires_at,
           scopes: payload_get(token_payload, :scopes) || grant.scopes || []
         }}
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
