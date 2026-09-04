defmodule Zaq.System do
  @moduledoc """
  Context for persistent system configuration stored in the database.
  Replaces environment-variable-based configuration for settings that should
  be managed at runtime from the back office.
  """

  import Ecto.Query

  alias Zaq.Engine.Connect
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Engine.Telemetry.Collector
  alias Zaq.Event
  alias Zaq.Ingestion.Chunk
  alias Zaq.NodeRouter
  alias Zaq.Repo
  alias Zaq.System.AIProviderCredential
  alias Zaq.System.Config
  alias Zaq.System.EmbeddingConfig
  alias Zaq.System.HttpCredentialProvider
  alias Zaq.System.HttpCredentialProviderRef
  alias Zaq.System.ImageToTextConfig
  alias Zaq.System.LLMConfig
  alias Zaq.System.OutboundHttpPolicy
  alias Zaq.System.TelemetryConfig
  alias Zaq.Types.EncryptedString
  alias Zaq.Utils.ParseUtils

  @telemetry_fields ~w(
    capture_infra_metrics
    request_duration_threshold_ms
    repo_query_duration_threshold_ms
    no_answer_alert_threshold_percent
    conversation_response_sla_ms
  )
  @llm_read_fields ~w(credential_id model temperature top_p path supports_logprobs supports_json_mode max_context_window distance_threshold fusion_bm25_weight fusion_vector_weight)
  @llm_write_fields ~w(credential_id model temperature top_p path supports_logprobs supports_json_mode max_context_window distance_threshold fusion_bm25_weight fusion_vector_weight)
  @embedding_read_fields ~w(credential_id model dimension chunk_min_tokens chunk_max_tokens)
  @embedding_write_fields ~w(credential_id model dimension chunk_min_tokens chunk_max_tokens)
  @image_to_text_read_fields ~w(credential_id model)
  @image_to_text_write_fields ~w(credential_id model)
  @global_base_url_key "system.global.base_url"
  @system_language_key "system.global.language"
  @system_timezone_key "system.global.timezone"
  @outbound_http_policy_fields ~w(
    enabled
    block_loopback
    block_private_networks
    block_link_local
    block_cloud_metadata
    block_carrier_grade_nat
    block_multicast
    block_unspecified
    block_reserved
    block_ipv6_unique_local
    blacklisted_hosts
    blacklisted_ips
    blacklisted_cidrs
    allowed_methods
    allowed_ports
    max_timeout_ms
    max_response_bytes
    follow_redirects
  )

  @skill_resource_prefix "system.agent_skills.resources"
  # ── Generic key/value ─────────────────────────────────────────────────

  @doc "Returns the stored value for `key`, or `nil`."
  def get_config(key) do
    case Repo.get_by(Config, key: key) do
      nil -> nil
      row -> row.value
    end
  end

  @doc "Upserts a single config entry."
  def set_config(key, value) do
    string_value = to_string(value)

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    %Config{}
    |> Config.changeset(%{key: key, value: string_value})
    |> Repo.insert(
      on_conflict: [set: [value: string_value, updated_at: now]],
      conflict_target: :key
    )
  end

  @doc "Returns globally configured default agent id, or nil when unset."
  @spec get_global_default_agent_id() :: integer() | nil
  def get_global_default_agent_id do
    case IncomingMessageRouting.get_rule(%{}) do
      %{routing_mode: :agent, configured_agent_id: configured_agent_id} -> configured_agent_id
      _ -> nil
    end
  end

  @doc "Sets or clears globally configured default agent id."
  @spec set_global_default_agent_id(integer() | String.t() | nil) :: :ok | {:error, term()}
  def set_global_default_agent_id(agent_id) do
    rule =
      case ParseUtils.parse_optional_int(agent_id, nil) do
        nil -> %{routing_mode: :clear}
        id -> %{routing_mode: :agent, configured_agent_id: id}
      end

    case dispatch_incoming_routing_rules([rule]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_incoming_routing_rules(rules) do
    %{rules: rules, raw_errors: true}
    |> Event.new(:engine, opts: [action: :upsert_incoming_message_routing_rules])
    |> NodeRouter.dispatch()
    |> Map.get(:response)
  end

  @doc "Returns globally configured base URL, or nil when unset."
  @spec get_global_base_url() :: String.t() | nil
  def get_global_base_url do
    case get_config(@global_base_url_key) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  @doc "Sets or clears globally configured base URL."
  @spec set_global_base_url(String.t() | nil) :: :ok | {:error, term()}
  def set_global_base_url(base_url) do
    value = if is_binary(base_url), do: String.trim(base_url), else: ""

    case set_config(@global_base_url_key, value) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the configured system language, or \"en\" by default."
  @spec get_system_language() :: String.t()
  def get_system_language do
    get_config(@system_language_key) || "en"
  end

  @doc "Sets the system language."
  @spec set_system_language(String.t()) :: :ok | {:error, term()}
  def set_system_language(language) do
    case set_config(@system_language_key, language) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the configured system timezone, or nil by default."
  @spec get_system_timezone() :: String.t() | nil
  def get_system_timezone do
    case get_config(@system_timezone_key) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  @doc "Sets the system timezone."
  @spec set_system_timezone(String.t() | nil) :: :ok | {:error, term()}
  def set_system_timezone(timezone) do
    value = if is_binary(timezone), do: String.trim(timezone), else: ""

    case set_config(@system_timezone_key, value) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the global default data-source location for new skill resources."
  def get_skill_resource_config do
    %{
      provider: blank_to_nil(get_config("#{@skill_resource_prefix}.provider")),
      config_id: parse_optional_int_config("#{@skill_resource_prefix}.config_id"),
      scope_id: blank_to_nil(get_config("#{@skill_resource_prefix}.scope_id")),
      folder_id: blank_to_nil(get_config("#{@skill_resource_prefix}.folder_id")),
      folder_path: blank_to_nil(get_config("#{@skill_resource_prefix}.folder_path"))
    }
  end

  @doc "Persists the global default data-source location for new skill resources."
  def save_skill_resource_config(attrs) when is_map(attrs) do
    config = normalize_skill_resource_config(attrs)

    Enum.each(config, fn {field, value} ->
      set_config("#{@skill_resource_prefix}.#{field}", value || "")
    end)

    {:ok, get_skill_resource_config()}
  end

  defp normalize_skill_resource_config(attrs) do
    %{
      provider: blank_to_nil(Map.get(attrs, :provider) || Map.get(attrs, "provider")),
      config_id:
        ParseUtils.parse_optional_int(
          Map.get(attrs, :config_id) || Map.get(attrs, "config_id"),
          nil
        ),
      scope_id: blank_to_nil(Map.get(attrs, :scope_id) || Map.get(attrs, "scope_id")),
      folder_id: blank_to_nil(Map.get(attrs, :folder_id) || Map.get(attrs, "folder_id")),
      folder_path: blank_to_nil(Map.get(attrs, :folder_path) || Map.get(attrs, "folder_path"))
    }
  end

  defp parse_optional_int_config(key), do: ParseUtils.parse_optional_int(get_config(key), nil)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: value

  # ── Telemetry ─────────────────────────────────────────────────────────

  @doc "Loads telemetry collection settings from DB as `%TelemetryConfig{}`."
  def get_telemetry_config do
    keys = Enum.map(@telemetry_fields, &"telemetry.#{&1}")
    rows = Repo.all(from c in Config, where: c.key in ^keys)

    raw =
      Enum.reduce(rows, %{}, fn row, acc ->
        short = String.replace_prefix(row.key, "telemetry.", "")
        Map.put(acc, short, row.value)
      end)

    %TelemetryConfig{
      capture_infra_metrics: ParseUtils.parse_bool(raw["capture_infra_metrics"], false),
      request_duration_threshold_ms:
        ParseUtils.parse_int(raw["request_duration_threshold_ms"], 10),
      repo_query_duration_threshold_ms:
        ParseUtils.parse_int(raw["repo_query_duration_threshold_ms"], 5),
      no_answer_alert_threshold_percent:
        ParseUtils.parse_int(raw["no_answer_alert_threshold_percent"], 10),
      conversation_response_sla_ms:
        ParseUtils.parse_int(raw["conversation_response_sla_ms"], 1500)
    }
  end

  @doc "Persists telemetry settings from a validated `%TelemetryConfig{}` changeset."
  def save_telemetry_config(%Ecto.Changeset{valid?: true} = changeset) do
    config = Ecto.Changeset.apply_changes(changeset)

    Enum.each(@telemetry_fields, fn field ->
      value = Map.get(config, String.to_existing_atom(field))
      set_config("telemetry.#{field}", value)
    end)

    maybe_reload_telemetry_collector()

    {:ok, config}
  end

  def save_telemetry_config(%Ecto.Changeset{valid?: false} = changeset), do: {:error, changeset}

  # ── Outbound HTTP ─────────────────────────────────────────────────────

  @doc "Loads the global outbound HTTP security policy."
  def get_outbound_http_policy do
    keys = Enum.map(@outbound_http_policy_fields, &"outbound_http.#{&1}")
    rows = Repo.all(from c in Config, where: c.key in ^keys)

    raw =
      Map.new(rows, fn row ->
        {String.replace_prefix(row.key, "outbound_http.", ""), row.value}
      end)

    %OutboundHttpPolicy{
      enabled: ParseUtils.parse_bool(raw["enabled"], false),
      block_loopback: ParseUtils.parse_bool(raw["block_loopback"], true),
      block_private_networks: ParseUtils.parse_bool(raw["block_private_networks"], true),
      block_link_local: ParseUtils.parse_bool(raw["block_link_local"], true),
      block_cloud_metadata: ParseUtils.parse_bool(raw["block_cloud_metadata"], true),
      block_carrier_grade_nat: ParseUtils.parse_bool(raw["block_carrier_grade_nat"], true),
      block_multicast: ParseUtils.parse_bool(raw["block_multicast"], true),
      block_unspecified: ParseUtils.parse_bool(raw["block_unspecified"], true),
      block_reserved: ParseUtils.parse_bool(raw["block_reserved"], true),
      block_ipv6_unique_local: ParseUtils.parse_bool(raw["block_ipv6_unique_local"], true),
      blacklisted_hosts: parse_string_list(raw["blacklisted_hosts"]),
      blacklisted_ips: parse_string_list(raw["blacklisted_ips"]),
      blacklisted_cidrs: parse_string_list(raw["blacklisted_cidrs"]),
      allowed_methods:
        parse_string_list(raw["allowed_methods"], OutboundHttpPolicy.safe_methods()),
      allowed_ports: parse_integer_list(raw["allowed_ports"]),
      max_timeout_ms: ParseUtils.parse_int(raw["max_timeout_ms"], 30_000),
      max_response_bytes: ParseUtils.parse_int(raw["max_response_bytes"], 100_000),
      follow_redirects: ParseUtils.parse_bool(raw["follow_redirects"], false)
    }
  end

  @doc "Persists a validated global outbound HTTP security policy."
  def save_outbound_http_policy(%Ecto.Changeset{valid?: true} = changeset) do
    policy = Ecto.Changeset.apply_changes(changeset)
    persist_config_values(@outbound_http_policy_fields, "outbound_http", policy)
    {:ok, get_outbound_http_policy()}
  end

  def save_outbound_http_policy(%Ecto.Changeset{valid?: false} = changeset),
    do: {:error, changeset}

  # ── HTTP Credential Providers ────────────────────────────────────────

  @doc "Lists BO-managed dynamic HTTP credential providers."
  def list_http_credential_providers do
    HttpCredentialProvider
    |> order_by([provider], asc: provider.name)
    |> Repo.all()
  end

  @doc "Gets a BO-managed dynamic HTTP credential provider by id."
  def get_http_credential_provider(id), do: Repo.get(HttpCredentialProvider, id)

  @doc "Gets a BO-managed dynamic HTTP credential provider by id, raising when absent."
  def get_http_credential_provider!(id), do: Repo.get!(HttpCredentialProvider, id)

  @doc "Returns a changeset for BO-managed dynamic HTTP credential providers."
  def change_http_credential_provider(%HttpCredentialProvider{} = provider, attrs \\ %{}) do
    HttpCredentialProvider.changeset(provider, attrs)
  end

  @doc "Creates a BO-managed dynamic HTTP credential provider."
  def create_http_credential_provider(attrs \\ %{}) do
    %HttpCredentialProvider{}
    |> HttpCredentialProvider.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Updates a BO-managed dynamic HTTP credential provider."
  def update_http_credential_provider(%HttpCredentialProvider{} = provider, attrs) do
    provider
    |> HttpCredentialProvider.changeset(attrs)
    |> Repo.update()
  end

  @doc "Deletes a BO-managed dynamic HTTP credential provider."
  def delete_http_credential_provider(%HttpCredentialProvider{} = provider) do
    {:ok, provider_ref} = HttpCredentialProviderRef.format(provider.id)

    usage_count =
      Connect.Credential
      |> where([credential], credential.provider == ^provider_ref)
      |> Repo.aggregate(:count, :id)

    if usage_count == 0 do
      Repo.delete(provider)
    else
      changeset =
        provider
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(
          :id,
          "is referenced by #{usage_count} Auth Credential#{if usage_count == 1, do: "", else: "s"}"
        )

      {:error, changeset}
    end
  end

  # ── LLM ───────────────────────────────────────────────────────────────

  @doc "Loads LLM configuration from DB as `%LLMConfig{}`."
  def get_llm_config do
    keys = Enum.map(@llm_read_fields, &"llm.#{&1}")
    rows = Repo.all(from c in Config, where: c.key in ^keys)
    raw = Map.new(rows, fn row -> {String.replace_prefix(row.key, "llm.", ""), row.value} end)
    build_llm_config(raw)
  end

  defp build_llm_config(raw) do
    config =
      %LLMConfig{
        credential_id: ParseUtils.parse_int(raw["credential_id"], nil),
        provider: "custom",
        endpoint: "http://localhost:11434/v1",
        api_key: "",
        model: raw["model"] || "llama-3.3-70b-instruct",
        temperature: ParseUtils.parse_float(raw["temperature"], 0.0),
        top_p: ParseUtils.parse_float(raw["top_p"], 0.9),
        path: raw["path"] || "/chat/completions",
        supports_logprobs: ParseUtils.parse_bool(raw["supports_logprobs"], true),
        supports_json_mode: ParseUtils.parse_bool(raw["supports_json_mode"], true),
        max_context_window: ParseUtils.parse_int(raw["max_context_window"], 5_000),
        distance_threshold: ParseUtils.parse_float(raw["distance_threshold"], 1.2),
        fusion_bm25_weight: ParseUtils.parse_float(raw["fusion_bm25_weight"], 0.5),
        fusion_vector_weight: ParseUtils.parse_float(raw["fusion_vector_weight"], 0.5)
      }

    merge_connection_fields_from_credential(config)
  end

  @doc "Persists LLM settings from a validated `%LLMConfig{}` changeset."
  def save_llm_config(%Ecto.Changeset{valid?: true} = changeset) do
    config = Ecto.Changeset.apply_changes(changeset)
    persist_config_values(@llm_write_fields, "llm", config)
    {:ok, get_llm_config()}
  end

  def save_llm_config(%Ecto.Changeset{valid?: false} = changeset), do: {:error, changeset}

  # ── Embedding ─────────────────────────────────────────────────────────

  @doc "Loads Embedding configuration from DB as `%EmbeddingConfig{}`."
  def get_embedding_config do
    keys = Enum.map(@embedding_read_fields, &"embedding.#{&1}")
    rows = Repo.all(from c in Config, where: c.key in ^keys)

    raw =
      Map.new(rows, fn row -> {String.replace_prefix(row.key, "embedding.", ""), row.value} end)

    build_embedding_config(raw)
  end

  defp build_embedding_config(raw) do
    config =
      %EmbeddingConfig{
        credential_id: ParseUtils.parse_int(raw["credential_id"], nil),
        provider: "custom",
        endpoint: "http://localhost:11434/v1",
        api_key: "",
        model: raw["model"] || "bge-multilingual-gemma2",
        dimension: ParseUtils.parse_int(raw["dimension"], 3584),
        chunk_min_tokens: ParseUtils.parse_int(raw["chunk_min_tokens"], 400),
        chunk_max_tokens: ParseUtils.parse_int(raw["chunk_max_tokens"], 900)
      }

    merge_connection_fields_from_credential(config)
  end

  @doc "Returns true when the chunks table exists in the database."
  def embedding_ready?, do: Chunk.table_exists?()

  @doc "Persists Embedding settings from a validated `%EmbeddingConfig{}` changeset."
  def save_embedding_config(%Ecto.Changeset{valid?: true} = changeset) do
    new_config = Ecto.Changeset.apply_changes(changeset)
    saved_model = get_config("embedding.model")

    multi = build_embedding_multi(new_config, saved_model)

    case Repo.transaction(multi) do
      {:ok, _} -> {:ok, get_embedding_config()}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def save_embedding_config(%Ecto.Changeset{valid?: false} = changeset), do: {:error, changeset}

  # ── Image to Text ──────────────────────────────────────────────────────

  @doc "Loads Image-to-Text configuration from DB as `%ImageToTextConfig{}`."
  def get_image_to_text_config do
    keys = Enum.map(@image_to_text_read_fields, &"image_to_text.#{&1}")
    rows = Repo.all(from c in Config, where: c.key in ^keys)

    raw =
      Map.new(rows, fn row ->
        {String.replace_prefix(row.key, "image_to_text.", ""), row.value}
      end)

    config =
      %ImageToTextConfig{
        credential_id: ParseUtils.parse_int(raw["credential_id"], nil),
        provider: "custom",
        endpoint: "http://localhost:11434/v1",
        api_key: "",
        model: raw["model"] || "pixtral-12b-2409"
      }

    merge_connection_fields_from_credential(config)
  end

  @doc "Persists Image-to-Text settings from a validated `%ImageToTextConfig{}` changeset."
  def save_image_to_text_config(%Ecto.Changeset{valid?: true} = changeset) do
    config = Ecto.Changeset.apply_changes(changeset)
    persist_config_values(@image_to_text_write_fields, "image_to_text", config)
    {:ok, get_image_to_text_config()}
  end

  def save_image_to_text_config(%Ecto.Changeset{valid?: false} = changeset),
    do: {:error, changeset}

  # ── AI Provider Credentials ────────────────────────────────────────────

  @doc "Lists all AI provider credentials."
  def list_ai_provider_credentials do
    AIProviderCredential
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  @doc "Gets an AI provider credential by id, raising if not found."
  def get_ai_provider_credential!(id), do: Repo.get!(AIProviderCredential, id)

  @doc "Gets an AI provider credential by id, returning `nil` when not found."
  def get_ai_provider_credential(id), do: Repo.get(AIProviderCredential, id)

  @doc "Gets an AI provider credential by name, returning `nil` when not found."
  def get_ai_provider_credential_by_name(name) when is_binary(name) do
    Repo.get_by(AIProviderCredential, name: name)
  end

  @doc "Returns the configured API key, or a resolved Connect bearer token when no API key is stored."
  @spec resolve_ai_provider_api_key(AIProviderCredential.t() | nil) :: String.t()
  def resolve_ai_provider_api_key(nil), do: ""

  def resolve_ai_provider_api_key(%AIProviderCredential{provider: "openai_codex"} = credential),
    do: resolve_ai_provider_bearer_token(credential)

  def resolve_ai_provider_api_key(%AIProviderCredential{api_key: api_key})
      when is_binary(api_key) and api_key != "",
      do: api_key

  def resolve_ai_provider_api_key(%AIProviderCredential{} = credential),
    do: resolve_ai_provider_bearer_token(credential)

  defp resolve_ai_provider_bearer_token(%AIProviderCredential{} = credential) do
    case Connect.resolve_bearer_token(%{
           provider: ai_provider_oauth_provider(credential),
           resource_type: "ai_provider_credential",
           resource_id: credential.id,
           owner_type: "org"
         }) do
      {:ok, token} -> token
      {:error, _} -> ""
    end
  end

  defp ai_provider_oauth_provider(%AIProviderCredential{provider: "openai_codex"}), do: "openai"
  defp ai_provider_oauth_provider(%AIProviderCredential{provider: provider}), do: provider

  @doc "Returns a changeset for AI provider credentials."
  def change_ai_provider_credential(%AIProviderCredential{} = credential, attrs \\ %{}) do
    AIProviderCredential.changeset(credential, attrs)
  end

  @doc "Creates an AI provider credential."
  def create_ai_provider_credential(attrs \\ %{}) do
    %AIProviderCredential{}
    |> AIProviderCredential.changeset(attrs)
    |> save_ai_provider_credential(:insert)
  end

  @doc "Updates an AI provider credential."
  def update_ai_provider_credential(%AIProviderCredential{} = credential, attrs) do
    attrs = maybe_drop_blank_api_key(attrs)

    credential
    |> AIProviderCredential.changeset(attrs)
    |> save_ai_provider_credential(:update)
  end

  @doc "Deletes an AI provider credential unless referenced by system configs."
  def delete_ai_provider_credential(%AIProviderCredential{} = credential) do
    case credential_usage_keys(credential.id) do
      [] ->
        Repo.delete(credential)

      _in_use_keys ->
        {:error,
         Ecto.Changeset.add_error(
           Ecto.Changeset.change(credential),
           :base,
           "cannot delete credential currently used by system configuration"
         )}
    end
  end

  defp save_ai_provider_credential(%Ecto.Changeset{} = changeset, operation) do
    case encrypt_secret_field(changeset, :api_key, Ecto.Changeset.get_change(changeset, :api_key)) do
      {:ok, :skip} ->
        persist_ai_provider_credential(changeset, operation)

      {:ok, encrypted_api_key} ->
        changeset
        |> Ecto.Changeset.put_change(:api_key, encrypted_api_key)
        |> persist_ai_provider_credential(operation)

      {:error, %Ecto.Changeset{} = failed_changeset} ->
        {:error, failed_changeset}
    end
  end

  defp persist_ai_provider_credential(changeset, :insert), do: Repo.insert(changeset)
  defp persist_ai_provider_credential(changeset, :update), do: Repo.update(changeset)

  defp maybe_drop_blank_api_key(attrs) when is_map(attrs) do
    attrs
    |> Map.drop(blank_api_key_attr_keys(attrs))
  end

  defp blank_api_key_attr_keys(attrs) do
    []
    |> maybe_add_blank_key(attrs, :api_key)
    |> maybe_add_blank_key(attrs, "api_key")
  end

  defp maybe_add_blank_key(keys, attrs, key) do
    if Map.get(attrs, key) == "" do
      [key | keys]
    else
      keys
    end
  end

  defp merge_connection_fields_from_credential(%{credential_id: nil} = config), do: config

  defp merge_connection_fields_from_credential(config) do
    case Repo.get(AIProviderCredential, config.credential_id) do
      %AIProviderCredential{} = credential ->
        %{
          config
          | provider: credential.provider,
            endpoint: credential.endpoint,
            api_key: resolve_ai_provider_api_key(credential)
        }

      _ ->
        config
    end
  end

  defp credential_usage_keys(id) do
    id_value = to_string(id)

    ["llm.credential_id", "embedding.credential_id", "image_to_text.credential_id"]
    |> Enum.filter(fn key -> get_config(key) == id_value end)
  end

  defp persist_embedding_field(field, value), do: set_config("embedding.#{field}", value)

  defp persist_config_values(fields, namespace, config) do
    Enum.each(fields, fn field ->
      value = encrypted_field_value(field, config)
      set_config("#{namespace}.#{field}", value)
    end)
  end

  defp encrypted_field_value(field, config)
       when field in [
              "blacklisted_hosts",
              "blacklisted_ips",
              "blacklisted_cidrs",
              "allowed_methods",
              "allowed_ports"
            ] do
    config
    |> Map.get(String.to_existing_atom(field))
    |> Jason.encode!()
  end

  defp encrypted_field_value(field, config),
    do: Map.get(config, String.to_existing_atom(field))

  defp parse_string_list(nil), do: []
  defp parse_string_list(""), do: []
  defp parse_string_list(value), do: parse_string_list(value, [])

  defp parse_string_list(nil, default), do: default
  defp parse_string_list("", default), do: default

  defp parse_string_list(value, default) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, values} when is_list(values) -> Enum.map(values, &to_string/1)
      _ -> default
    end
  end

  defp parse_integer_list(nil), do: []
  defp parse_integer_list(""), do: []

  defp parse_integer_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, values} when is_list(values) ->
        values
        |> Enum.map(fn
          value when is_integer(value) -> value
          value -> ParseUtils.parse_int(value, nil)
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp build_embedding_multi(new_config, saved_model) do
    @embedding_write_fields
    |> Enum.reduce(Ecto.Multi.new(), fn field, multi ->
      value = encrypted_field_value(field, new_config)

      Ecto.Multi.run(multi, {:config, field}, fn _repo, _changes ->
        persist_embedding_field(field, value)
      end)
    end)
    |> Ecto.Multi.run(:table_op, fn _repo, _changes ->
      embedding_table_op(new_config, saved_model)
    end)
  end

  defp embedding_table_op(new_config, saved_model) do
    cond do
      not Chunk.table_exists?() ->
        {:ok, Chunk.create_table(new_config.dimension)}

      saved_model != nil and saved_model != new_config.model ->
        {:ok, Chunk.reset_table(new_config.dimension)}

      true ->
        {:ok, :noop}
    end
  end

  defp encrypt_secret_field(_changeset, _field, value) when value in [nil, ""],
    do: {:ok, :skip}

  defp encrypt_secret_field(changeset, field, value) when is_binary(value) do
    if EncryptedString.encrypted?(value) do
      {:ok, value}
    else
      case EncryptedString.encrypt(value) do
        {:ok, encrypted} -> {:ok, encrypted}
        {:error, reason} -> {:error, secret_encryption_error(changeset, field, reason)}
      end
    end
  end

  defp secret_encryption_error(changeset, field, :missing_encryption_key) do
    Ecto.Changeset.add_error(
      Ecto.Changeset.delete_change(changeset, field),
      field,
      "could not be encrypted: missing SYSTEM_CONFIG_ENCRYPTION_KEY"
    )
  end

  defp secret_encryption_error(changeset, field, :invalid_encryption_key) do
    Ecto.Changeset.add_error(
      Ecto.Changeset.delete_change(changeset, field),
      field,
      "could not be encrypted: invalid SYSTEM_CONFIG_ENCRYPTION_KEY"
    )
  end

  defp secret_encryption_error(changeset, field, _reason) do
    changeset
    |> Ecto.Changeset.delete_change(field)
    |> Ecto.Changeset.add_error(field, "could not be encrypted")
  end

  defp maybe_reload_telemetry_collector do
    if Process.whereis(Collector) do
      Collector.reload_policy()
    end

    :ok
  end
end
