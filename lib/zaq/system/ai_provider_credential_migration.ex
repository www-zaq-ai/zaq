defmodule Zaq.System.AIProviderCredentialMigration do
  @moduledoc """
  Secret-free compatibility preflight for the AI-provider-to-Connect cutover.

  This module may inspect encrypted legacy storage, but its result contains only IDs,
  classification atoms and fixed reasons. It does not migrate, decrypt into logs, infer
  no-auth from corrupt secrets or incomplete OAuth setup, or expose an Action/tool
  boundary. Legacy API-key-mode rows with no usable key are classified as no-auth.
  """

  import Ecto.Query

  alias Zaq.Engine.Connect.Grant
  alias Zaq.Repo
  alias Zaq.System.SecretConfig

  @default_limit 100
  @max_limit 500
  @ready [:already_migrated, :api_key, :oauth2, :no_auth]

  @type classification ::
          :already_migrated
          | :api_key
          | :oauth2
          | :no_auth
          | :missing_auth
          | :ambiguous
          | :unreadable

  @type item :: %{
          ai_provider_credential_id: pos_integer(),
          classification: classification(),
          reason: atom() | nil,
          source_grant_id: pos_integer() | nil,
          source_connect_credential_id: pos_integer() | nil
        }

  @spec preflight(keyword()) ::
          {:ok, %{items: [item()], ready?: boolean(), next_after_id: non_neg_integer() | nil}}
          | {:error, :invalid_options}
  def preflight(opts \\ []) do
    with {:ok, after_id, limit} <- pagination(opts),
         {:ok, %{rows: rows}} <- raw_rows(after_id, limit) do
      items = Enum.map(rows, &classify/1)

      {:ok,
       %{
         items: items,
         ready?: Enum.all?(items, &(&1.classification in @ready)),
         next_after_id: if(length(rows) == limit, do: rows |> List.last() |> hd(), else: nil)
       }}
    else
      _ -> {:error, :invalid_options}
    end
  end

  @doc false
  @spec classify_legacy_row([term()]) :: item()
  def classify_legacy_row(row), do: classify(row)

  defp pagination(opts) when is_list(opts) do
    after_id = Keyword.get(opts, :after_id, 0)
    limit = Keyword.get(opts, :limit, @default_limit)

    if is_integer(after_id) and after_id >= 0 and is_integer(limit) and limit in 1..@max_limit,
      do: {:ok, after_id, limit},
      else: {:error, :invalid_options}
  end

  defp pagination(_), do: {:error, :invalid_options}

  defp raw_rows(after_id, limit) do
    Repo.query(
      """
      SELECT id, api_key, metadata, connect_credential_id, provider
      FROM ai_provider_credentials
      WHERE id > $1
      ORDER BY id
      LIMIT $2
      """,
      [after_id, limit]
    )
  end

  defp classify([id, raw, metadata, connect_id]),
    do: classify([id, raw, metadata, connect_id, nil])

  defp classify([id, _raw, _metadata, connect_id, _provider]) when is_integer(connect_id) do
    item(id, :already_migrated, nil, nil, connect_id)
  end

  defp classify([id, raw, metadata, nil, provider]) do
    case legacy_grants(id) do
      [%{id: grant_id, credential_id: credential_id, auth_kind: "oauth2"}] ->
        item(id, :oauth2, nil, grant_id, credential_id)

      [] ->
        if provider == "openai_codex",
          do: item(id, :missing_auth, :incomplete_oauth),
          else: classify_without_grant(id, raw, metadata)

      _ ->
        item(id, :ambiguous, :legacy_grant_set)
    end
  end

  defp classify_without_grant(id, raw, metadata) do
    cond do
      oauth_intent?(metadata) -> item(id, :missing_auth, :incomplete_oauth)
      explicit_no_auth?(metadata) and is_nil(raw) -> item(id, :no_auth)
      is_nil(raw) or raw == "" -> keyless_classification(id, metadata)
      present_raw?(raw) -> classify_api_key(id, raw, metadata)
      true -> item(id, :unreadable, :invalid_api_key_storage)
    end
  end

  defp classify_api_key(id, raw, metadata) do
    case SecretConfig.decrypt(raw) do
      {:ok, value} when is_binary(value) ->
        cond do
          String.trim(value) == "" -> keyless_classification(id, metadata)
          explicit_no_auth?(metadata) -> item(id, :ambiguous, :no_auth_with_api_key)
          true -> item(id, :api_key)
        end

      _ ->
        item(id, :unreadable, :api_key_decryption_failed)
    end
  end

  defp keyless_classification(id, metadata) when is_map(metadata) do
    if Map.get(metadata, "auth_kind", Map.get(metadata, :auth_kind)) in [nil, "api_key", "none"],
      do: item(id, :no_auth),
      else: item(id, :missing_auth, :unsupported_auth_kind)
  end

  defp keyless_classification(id, _), do: item(id, :missing_auth, :no_explicit_authentication)

  defp oauth_intent?(metadata) when is_map(metadata) do
    Map.get(metadata, "auth_kind", Map.get(metadata, :auth_kind)) == "oauth2" or
      Enum.any?(
        [
          "auth_profile",
          "client_id",
          "authorize_url",
          "token_url",
          :auth_profile,
          :client_id,
          :authorize_url,
          :token_url
        ],
        &Map.has_key?(metadata, &1)
      )
  end

  defp oauth_intent?(_), do: false

  defp legacy_grants(id) do
    Repo.all(
      from g in Grant,
        where:
          g.resource_type == "ai_provider_credential" and g.resource_id == ^to_string(id) and
            g.owner_type == "org" and is_nil(g.owner_id),
        order_by: g.id,
        select: %{id: g.id, credential_id: g.credential_id, auth_kind: g.auth_kind}
    )
  end

  defp item(id, classification, reason \\ nil, grant_id \\ nil, credential_id \\ nil) do
    %{
      ai_provider_credential_id: id,
      classification: classification,
      reason: reason,
      source_grant_id: grant_id,
      source_connect_credential_id: credential_id
    }
  end

  defp explicit_no_auth?(metadata) when is_map(metadata),
    do: Map.get(metadata, "auth_kind") == "none" or Map.get(metadata, :auth_kind) == "none"

  defp explicit_no_auth?(_), do: false
  defp present_raw?(value), do: is_binary(value) and byte_size(value) > 0
end
