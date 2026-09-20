defmodule Zaq.System.AIProviderCredentialConfiguration do
  @moduledoc """
  Atomic mapping from AI-specific provider records to canonical Connect authentication.

  AI provider/endpoint/sovereign fields remain in System. This module translates only
  administrator-owned authentication configuration and delegates all grant writes,
  encryption, policy validation and mutation events to `Zaq.Engine.Connect.Mutations`.
  """

  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.Credential
  alias Zaq.Repo
  alias Zaq.System.AIProviderCredential
  alias Zaq.Utils.Map, as: MapUtils

  @spec save(AIProviderCredential.t() | nil, map(), keyword()) ::
          {:ok, pos_integer()} | {:error, atom()}
  def save(current, attrs, opts \\ [])

  def save(current, attrs, opts) when is_map(attrs) do
    candidate =
      current
      |> Kernel.||(%AIProviderCredential{})
      |> AIProviderCredential.changeset(attrs)
      |> Ecto.Changeset.apply_changes()

    existing = existing_connect(current)
    auth_kind = auth_kind(candidate, attrs, existing)

    config =
      candidate
      |> connect_attrs(existing, auth_kind, attrs)
      |> maybe_drop_nil_configuration(auth_kind)

    global = global_instruction(candidate, attrs, existing, auth_kind)

    case Connect.save_credential_configuration(existing, config, global, opts) do
      {:ok, %{credential_id: id}} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  def save(_, _, _), do: {:error, :invalid_configuration}

  defp existing_connect(%AIProviderCredential{connect_credential_id: id}) when is_integer(id),
    do: Repo.get(Credential, id)

  defp existing_connect(_), do: nil

  defp auth_kind(%AIProviderCredential{metadata: metadata, api_key: api_key}, attrs, existing) do
    submitted_kind = submitted_auth_kind(attrs)
    candidate_kind = MapUtils.metadata_value(metadata || %{}, "auth_kind")

    cond do
      submitted_kind in ["oauth2", "none"] -> submitted_kind
      submitted_secret?(attrs, :api_key) -> "api_key"
      not is_nil(existing) -> existing.auth_kind
      is_binary(api_key) and api_key != "" -> "api_key"
      candidate_kind in ["oauth2", "none"] -> candidate_kind
      true -> "api_key"
    end
  end

  defp submitted_auth_kind(attrs) do
    attrs
    |> Map.get(:metadata, Map.get(attrs, "metadata"))
    |> case do
      metadata when is_map(metadata) -> MapUtils.metadata_value(metadata, "auth_kind")
      _ -> nil
    end
  end

  defp connect_attrs(ai, existing, "none", _attrs) do
    base_attrs(ai, existing, "none")
    |> Map.merge(%{
      personal_credential_policy: :disabled,
      secret_binding: :configuration,
      metadata: %{},
      client_id: nil,
      client_secret: nil,
      scopes: [],
      api_key: nil,
      private_key: nil
    })
  end

  defp connect_attrs(ai, existing, "oauth2", attrs) do
    metadata = oauth_source_metadata(ai, existing, attrs)

    base_attrs(ai, existing, "oauth2")
    |> Map.merge(%{
      personal_credential_policy: policy(attrs, existing, :required),
      secret_binding: :grant,
      metadata: oauth_metadata(metadata),
      client_id: MapUtils.metadata_value(metadata, "client_id"),
      client_secret: MapUtils.metadata_value(metadata, "client_secret"),
      scopes: oauth_scopes(metadata)
    })
  end

  defp connect_attrs(ai, existing, "api_key", attrs) do
    base_attrs(ai, existing, "api_key")
    |> Map.merge(%{
      personal_credential_policy: policy(attrs, existing, :disabled),
      secret_binding: :grant,
      metadata: %{}
    })
  end

  defp oauth_source_metadata(ai, %Credential{} = existing, attrs) do
    if Map.has_key?(attrs, :metadata) or Map.has_key?(attrs, "metadata"),
      do: ai.metadata || %{},
      else: existing.metadata || %{}
  end

  defp oauth_source_metadata(ai, _existing, _attrs), do: ai.metadata || %{}

  defp base_attrs(ai, existing, auth_kind) do
    %{
      name: if(existing, do: existing.name, else: connect_name(ai.name)),
      provider: oauth_provider(ai.provider),
      auth_kind: auth_kind,
      request_format: if(existing, do: existing.request_format, else: "bearer"),
      user_level: false,
      metadata: %{},
      expires_at: if(existing, do: existing.expires_at)
    }
  end

  defp global_instruction(_candidate, _attrs, _existing, "none"), do: :remove

  defp global_instruction(_candidate, _attrs, %Credential{auth_kind: "oauth2"}, "oauth2"),
    do: :keep

  defp global_instruction(_candidate, _attrs, _existing, "oauth2"), do: :remove

  defp global_instruction(candidate, attrs, existing, "api_key") do
    cond do
      submitted_secret?(attrs, :api_key) -> {:replace, %{api_key: candidate.api_key}}
      is_nil(existing) -> :remove
      true -> :keep
    end
  end

  defp submitted_secret?(attrs, field) do
    value = Map.get(attrs, field, Map.get(attrs, Atom.to_string(field)))
    is_binary(value) and String.trim(value) != ""
  end

  defp policy(attrs, existing, default) do
    case Map.get(attrs, :personal_credential_policy, Map.get(attrs, "personal_credential_policy")) do
      value when value in [:disabled, :optional, :required] -> value
      value when value in ["disabled", "optional", "required"] -> String.to_existing_atom(value)
      _ -> policy(existing, default)
    end
  end

  defp policy(%Credential{personal_credential_policy: policy}, _default), do: policy
  defp policy(_, default), do: default

  defp connect_name(name), do: String.slice("AI: #{name}", 0, 255)
  defp oauth_provider("openai_codex"), do: "openai"
  defp oauth_provider(provider), do: provider

  defp oauth_scopes(metadata) do
    case MapUtils.metadata_value(metadata, "scope") do
      scope when is_binary(scope) -> String.split(scope)
      scopes when is_list(scopes) -> scopes
      _ -> []
    end
  end

  defp oauth_metadata(metadata) do
    metadata = MapUtils.stringify_keys(metadata)

    metadata
    |> Map.take(["authorize_url", "token_url", "auth_profile", "pkce"])
    |> maybe_put_authorize_params(metadata["authorize_params"])
  end

  defp maybe_put_authorize_params(metadata, params) when is_map(params) do
    allowed = ~w(prompt access_type include_granted_scopes login_hint audience)
    params = params |> MapUtils.stringify_keys() |> Map.take(allowed)
    if params == %{}, do: metadata, else: Map.put(metadata, "authorize_params", params)
  end

  defp maybe_put_authorize_params(metadata, _), do: metadata

  defp maybe_drop_nil_configuration(attrs, "none"), do: attrs

  defp maybe_drop_nil_configuration(attrs, _),
    do: Map.reject(attrs, fn {_key, value} -> is_nil(value) end)
end
