defmodule Zaq.System do
  @moduledoc """
  Context for persistent system configuration stored in the database.
  Replaces environment-variable-based configuration for settings that should
  be managed at runtime from the back office.
  """

  import Ecto.Query

  alias Zaq.Engine.Telemetry.Collector
  alias Zaq.Ingestion.Chunk
  alias Zaq.Repo
  alias Zaq.System.AIProviderCredential
  alias Zaq.System.Config
  alias Zaq.System.EmbeddingConfig
  alias Zaq.System.ImageToTextConfig
  alias Zaq.System.LLMConfig
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
  @llm_read_fields ~w(credential_id provider endpoint api_key model temperature top_p path supports_logprobs supports_json_mode max_context_window distance_threshold)
  @llm_write_fields ~w(credential_id model temperature top_p path supports_logprobs supports_json_mode max_context_window distance_threshold)
  @embedding_read_fields ~w(credential_id provider endpoint api_key model dimension chunk_min_tokens chunk_max_tokens)
  @embedding_write_fields ~w(credential_id model dimension chunk_min_tokens chunk_max_tokens)
  @image_to_text_read_fields ~w(credential_id provider endpoint api_key model)
  @image_to_text_write_fields ~w(credential_id model)

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
      capture_infra_metrics: parse_bool(raw["capture_infra_metrics"], false),
      request_duration_threshold_ms: parse_int(raw["request_duration_threshold_ms"], 10),
      repo_query_duration_threshold_ms: parse_int(raw["repo_query_duration_threshold_ms"], 5),
      no_answer_alert_threshold_percent: parse_int(raw["no_answer_alert_threshold_percent"], 10),
      conversation_response_sla_ms: parse_int(raw["conversation_response_sla_ms"], 1500)
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
        credential_id: parse_int(raw["credential_id"], nil),
        provider: raw["provider"] || "custom",
        endpoint: raw["endpoint"] || "http://localhost:11434/v1",
        api_key: EncryptedString.decrypt!(raw["api_key"]) || "",
        model: raw["model"] || "llama-3.3-70b-instruct",
        temperature: parse_float(raw["temperature"], 0.0),
        top_p: parse_float(raw["top_p"], 0.9),
        path: raw["path"] || "/chat/completions",
        supports_logprobs: parse_bool(raw["supports_logprobs"], true),
        supports_json_mode: parse_bool(raw["supports_json_mode"], true),
        max_context_window: parse_int(raw["max_context_window"], 5_000),
        distance_threshold: parse_float(raw["distance_threshold"], 1.2)
      }

    merge_connection_fields_from_credential(config)
  end

  @doc "Persists LLM settings from a validated `%LLMConfig{}` changeset."
  def save_llm_config(%Ecto.Changeset{valid?: true} = changeset) do
    config = Ecto.Changeset.apply_changes(changeset)
    persist_config_values(@llm_write_fields, "llm", config, :skip)
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
        credential_id: parse_int(raw["credential_id"], nil),
        provider: raw["provider"] || "custom",
        endpoint: raw["endpoint"] || "http://localhost:11434/v1",
        api_key: EncryptedString.decrypt!(raw["api_key"]) || "",
        model: raw["model"] || "bge-multilingual-gemma2",
        dimension: parse_int(raw["dimension"], 3584),
        chunk_min_tokens: parse_int(raw["chunk_min_tokens"], 400),
        chunk_max_tokens: parse_int(raw["chunk_max_tokens"], 900)
      }

    merge_connection_fields_from_credential(config)
  end

  @doc "Returns true when the chunks table exists in the database."
  def embedding_ready?, do: Chunk.table_exists?()

  @doc "Persists Embedding settings from a validated `%EmbeddingConfig{}` changeset."
  def save_embedding_config(%Ecto.Changeset{valid?: true} = changeset) do
    new_config = Ecto.Changeset.apply_changes(changeset)
    saved_model = get_config("embedding.model")

    multi = build_embedding_multi(new_config, :skip, saved_model)

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
        credential_id: parse_int(raw["credential_id"], nil),
        provider: raw["provider"] || "custom",
        endpoint: raw["endpoint"] || "http://localhost:11434/v1",
        api_key: EncryptedString.decrypt!(raw["api_key"]) || "",
        model: raw["model"] || "pixtral-12b-2409"
      }

    merge_connection_fields_from_credential(config)
  end

  @doc "Persists Image-to-Text settings from a validated `%ImageToTextConfig{}` changeset."
  def save_image_to_text_config(%Ecto.Changeset{valid?: true} = changeset) do
    config = Ecto.Changeset.apply_changes(changeset)
    persist_config_values(@image_to_text_write_fields, "image_to_text", config, :skip)
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

  @doc "Deletes an AI provider credential."
  def delete_ai_provider_credential(%AIProviderCredential{} = credential),
    do: Repo.delete(credential)

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
            api_key: credential.api_key || ""
        }

      _ ->
        config
    end
  end

  defp persist_embedding_field("api_key", value), do: set_config("embedding.api_key", value)

  defp persist_embedding_field(field, value), do: set_config("embedding.#{field}", value)

  defp persist_config_values(fields, namespace, config, encrypted_api_key) do
    Enum.each(fields, fn field ->
      case encrypted_field_value(field, config, encrypted_api_key) do
        :skip -> :ok
        value -> set_config("#{namespace}.#{field}", value)
      end
    end)
  end

  defp encrypted_field_value("api_key", _config, encrypted_api_key), do: encrypted_api_key

  defp encrypted_field_value(field, config, _encrypted_api_key),
    do: Map.get(config, String.to_existing_atom(field))

  defp build_embedding_multi(new_config, encrypted_api_key, saved_model) do
    @embedding_write_fields
    |> Enum.reject(&(&1 == "api_key" and encrypted_api_key == :skip))
    |> Enum.reduce(Ecto.Multi.new(), fn field, multi ->
      value = encrypted_field_value(field, new_config, encrypted_api_key)

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
      changeset,
      field,
      "could not be encrypted: missing SYSTEM_CONFIG_ENCRYPTION_KEY"
    )
  end

  defp secret_encryption_error(changeset, field, :invalid_encryption_key) do
    Ecto.Changeset.add_error(
      changeset,
      field,
      "could not be encrypted: invalid SYSTEM_CONFIG_ENCRYPTION_KEY"
    )
  end

  defp secret_encryption_error(changeset, field, _reason) do
    Ecto.Changeset.add_error(changeset, field, "could not be encrypted")
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp parse_int(str, default), do: ParseUtils.parse_int(str, default)

  defp parse_float(nil, default), do: default
  defp parse_float("", default), do: default

  defp parse_float(str, default) when is_binary(str) do
    case Float.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_float(n, _default) when is_float(n), do: n
  defp parse_float(n, _default) when is_integer(n), do: n / 1

  defp parse_bool(nil, default), do: default
  defp parse_bool(value, _default) when value in [true, "true", "1", 1], do: true
  defp parse_bool(_value, _default), do: false

  defp maybe_reload_telemetry_collector do
    if Process.whereis(Collector) do
      Collector.reload_policy()
    end

    :ok
  end
end
