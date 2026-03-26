defmodule Zaq.System do
  @moduledoc """
  Context for persistent system configuration stored in the database.
  Replaces environment-variable-based configuration for settings that should
  be managed at runtime from the back office.
  """

  import Ecto.Query

  alias Zaq.Engine.Telemetry.Collector
  alias Zaq.Repo
  alias Zaq.System.Config
  alias Zaq.System.EmailConfig
  alias Zaq.System.EmbeddingConfig
  alias Zaq.System.ImageToTextConfig
  alias Zaq.System.IngestionConfig
  alias Zaq.System.LLMConfig
  alias Zaq.System.TelemetryConfig
  alias Zaq.Types.EncryptedString

  @email_fields ~w(
    enabled relay port transport_mode tls tls_verify ca_cert_path username password from_email from_name
  )
  @telemetry_fields ~w(
    capture_infra_metrics
    request_duration_threshold_ms
    repo_query_duration_threshold_ms
    no_answer_alert_threshold_percent
    conversation_response_sla_ms
  )
  @llm_fields ~w(provider endpoint api_key model temperature top_p supports_logprobs supports_json_mode)
  @embedding_fields ~w(provider endpoint api_key model dimension)
  @image_to_text_fields ~w(provider api_url api_key model)
  @ingestion_fields ~w(max_context_window distance_threshold hybrid_search_limit chunk_min_tokens chunk_max_tokens base_path)

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

  # ── Email / SMTP ───────────────────────────────────────────────────────

  @doc """
  Loads email configuration from DB and returns an `%EmailConfig{}` struct.

  Sensitive values are decrypted when possible. For backward compatibility,
  legacy plaintext passwords are still readable.
  """
  def get_email_config do
    keys = Enum.map(@email_fields, &"email.#{&1}")
    rows = Repo.all(from c in Config, where: c.key in ^keys)

    raw =
      Enum.reduce(rows, %{}, fn row, acc ->
        short = String.replace_prefix(row.key, "email.", "")
        Map.put(acc, short, row.value)
      end)

    %EmailConfig{
      enabled: raw["enabled"] == "true",
      relay: raw["relay"],
      port: parse_int(raw["port"], 587),
      transport_mode: raw["transport_mode"] || "starttls",
      tls: raw["tls"] || "enabled",
      tls_verify: raw["tls_verify"] || "verify_peer",
      ca_cert_path: blank_to_nil(raw["ca_cert_path"]),
      username: raw["username"],
      password: decrypt_password_value(raw["password"]),
      from_email: raw["from_email"] || "noreply@zaq.local",
      from_name: raw["from_name"] || "ZAQ"
    }
  end

  @doc """
  Persists email config from a validated `%EmailConfig{}` changeset.

  SMTP password values are encrypted at rest via `Zaq.System.EncryptedString`.
  In strict mode, saves fail when a non-empty password is provided but
  encryption key configuration is missing or invalid.
  """
  def save_email_config(%Ecto.Changeset{valid?: true} = changeset) do
    config = Ecto.Changeset.apply_changes(changeset)

    case persist_email_fields(config) do
      :ok -> {:ok, config}
      {:error, reason} -> {:error, reason}
    end
  end

  def save_email_config(%Ecto.Changeset{valid?: false} = changeset), do: {:error, changeset}

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

  @doc """
  Returns `{:ok, keyword_list}` with Swoosh SMTP delivery options built from
  the DB config, or `{:error, :not_configured}` when email is disabled or the
  relay is not set.

  Returns decryption errors (for example `:invalid_ciphertext`) when an SMTP
  password is configured but cannot be decrypted.
  """
  def email_delivery_opts do
    cfg = get_email_config()

    with true <- cfg.enabled and not blank?(cfg.relay),
         {:ok, password} <- password_for_delivery(cfg) do
      {:ok, build_delivery_opts(cfg, password)}
    else
      false -> {:error, :not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the `{from_name, from_email}` tuple from DB config."
  def email_sender do
    cfg = get_email_config()
    {cfg.from_name || "ZAQ", cfg.from_email || "noreply@zaq.local"}
  end

  # ── LLM ───────────────────────────────────────────────────────────────

  @doc "Loads LLM configuration from DB as `%LLMConfig{}`, falling back to Application env."
  def get_llm_config do
    keys = Enum.map(@llm_fields, &"llm.#{&1}")
    rows = Repo.all(from c in Config, where: c.key in ^keys)
    raw = Map.new(rows, fn row -> {String.replace_prefix(row.key, "llm.", ""), row.value} end)
    app = Application.get_env(:zaq, Zaq.Agent.LLM, [])
    build_llm_config(raw, app)
  end

  defp build_llm_config(raw, app) do
    %LLMConfig{
      provider: raw_or(raw["provider"], app[:provider], "custom"),
      endpoint: raw_or(raw["endpoint"], app[:endpoint], "http://localhost:11434/v1"),
      api_key: raw_or(decrypt_api_key(raw["api_key"]), app[:api_key], ""),
      model: raw_or(raw["model"], app[:model], "llama-3.3-70b-instruct"),
      temperature: parse_float(raw["temperature"], app[:temperature] || 0.0),
      top_p: parse_float(raw["top_p"], app[:top_p] || 0.9),
      supports_logprobs: parse_bool(raw["supports_logprobs"], app[:supports_logprobs] || true),
      supports_json_mode: parse_bool(raw["supports_json_mode"], app[:supports_json_mode] || true)
    }
  end

  @doc "Persists LLM settings from a validated `%LLMConfig{}` changeset."
  def save_llm_config(%Ecto.Changeset{valid?: true} = changeset) do
    config = Ecto.Changeset.apply_changes(changeset)

    Enum.each(@llm_fields, fn field ->
      value = Map.get(config, String.to_existing_atom(field))

      case field do
        "api_key" when value in [nil, "", "••••••••"] -> :skip
        "api_key" -> set_config("llm.api_key", encrypt_api_key(value))
        _ -> set_config("llm.#{field}", value)
      end
    end)

    apply_llm_to_app_env()
    {:ok, get_llm_config()}
  end

  def save_llm_config(%Ecto.Changeset{valid?: false} = changeset), do: {:error, changeset}

  # ── Embedding ─────────────────────────────────────────────────────────

  @doc "Loads Embedding configuration from DB as `%EmbeddingConfig{}`, falling back to Application env."
  def get_embedding_config do
    keys = Enum.map(@embedding_fields, &"embedding.#{&1}")
    rows = Repo.all(from c in Config, where: c.key in ^keys)

    raw =
      Map.new(rows, fn row -> {String.replace_prefix(row.key, "embedding.", ""), row.value} end)

    app = Application.get_env(:zaq, Zaq.Embedding.Client, [])
    build_embedding_config(raw, app)
  end

  defp build_embedding_config(raw, app) do
    %EmbeddingConfig{
      provider: raw_or(raw["provider"], app[:provider], "custom"),
      endpoint: raw_or(raw["endpoint"], app[:endpoint], "http://localhost:11434/v1"),
      api_key: raw_or(decrypt_api_key(raw["api_key"]), app[:api_key], ""),
      model: raw_or(raw["model"], app[:model], "bge-multilingual-gemma2"),
      dimension: parse_int(raw["dimension"], app[:dimension] || 3584)
    }
  end

  @doc "Persists Embedding settings from a validated `%EmbeddingConfig{}` changeset."
  def save_embedding_config(%Ecto.Changeset{valid?: true} = changeset) do
    config = Ecto.Changeset.apply_changes(changeset)

    Enum.each(@embedding_fields, fn field ->
      value = Map.get(config, String.to_existing_atom(field))

      case field do
        "api_key" when value in [nil, "", "••••••••"] -> :skip
        "api_key" -> set_config("embedding.api_key", encrypt_api_key(value))
        _ -> set_config("embedding.#{field}", value)
      end
    end)

    apply_embedding_to_app_env()
    {:ok, get_embedding_config()}
  end

  def save_embedding_config(%Ecto.Changeset{valid?: false} = changeset), do: {:error, changeset}

  # ── Image to Text ──────────────────────────────────────────────────────

  @doc "Loads Image-to-Text configuration from DB as `%ImageToTextConfig{}`, falling back to Application env."
  def get_image_to_text_config do
    keys = Enum.map(@image_to_text_fields, &"image_to_text.#{&1}")
    rows = Repo.all(from c in Config, where: c.key in ^keys)

    raw =
      Map.new(rows, fn row ->
        {String.replace_prefix(row.key, "image_to_text.", ""), row.value}
      end)

    app = Application.get_env(:zaq, Zaq.Ingestion.Python.Steps.ImageToText, [])

    %ImageToTextConfig{
      api_url: raw["api_url"] || app[:api_url] || "http://localhost:11434/v1",
      api_key: decrypt_api_key(raw["api_key"]) || app[:api_key] || "",
      model: raw["model"] || app[:model] || "pixtral-12b-2409"
    }
  end

  @doc "Persists Image-to-Text settings from a validated `%ImageToTextConfig{}` changeset."
  def save_image_to_text_config(%Ecto.Changeset{valid?: true} = changeset) do
    config = Ecto.Changeset.apply_changes(changeset)

    Enum.each(@image_to_text_fields, fn field ->
      value = Map.get(config, String.to_existing_atom(field))

      case field do
        "api_key" when value in [nil, "", "••••••••"] -> :skip
        "api_key" -> set_config("image_to_text.api_key", encrypt_api_key(value))
        _ -> set_config("image_to_text.#{field}", value)
      end
    end)

    apply_image_to_text_to_app_env()
    {:ok, get_image_to_text_config()}
  end

  def save_image_to_text_config(%Ecto.Changeset{valid?: false} = changeset),
    do: {:error, changeset}

  # ── Startup ───────────────────────────────────────────────────────────

  @doc """
  Reads AI configs from DB and applies them to Application env.
  Called at startup to override runtime.exs env-var defaults with DB values.
  Safe to call when DB has no records (leaves Application env unchanged).
  """
  def apply_ai_configs_from_db do
    apply_llm_to_app_env()
    apply_embedding_to_app_env()
    apply_image_to_text_to_app_env()
    apply_ingestion_to_app_env()
  rescue
    _ -> :ok
  end

  # ── Ingestion ─────────────────────────────────────────────────────────

  @doc "Loads ingestion configuration from DB as `%IngestionConfig{}`, falling back to Application env."
  def get_ingestion_config do
    keys = Enum.map(@ingestion_fields, &"ingestion.#{&1}")
    rows = Repo.all(from c in Config, where: c.key in ^keys)

    raw =
      Map.new(rows, fn row -> {String.replace_prefix(row.key, "ingestion.", ""), row.value} end)

    app = Application.get_env(:zaq, Zaq.Ingestion, [])

    %IngestionConfig{
      max_context_window: parse_int(raw["max_context_window"], app[:max_context_window] || 5_000),
      distance_threshold: parse_float(raw["distance_threshold"], app[:distance_threshold] || 1.2),
      hybrid_search_limit: parse_int(raw["hybrid_search_limit"], app[:hybrid_search_limit] || 20),
      chunk_min_tokens: parse_int(raw["chunk_min_tokens"], app[:chunk_min_tokens] || 400),
      chunk_max_tokens: parse_int(raw["chunk_max_tokens"], app[:chunk_max_tokens] || 900),
      base_path: raw["base_path"] || app[:base_path] || "/zaq/volumes/documents"
    }
  end

  @doc "Persists ingestion settings from a validated `%IngestionConfig{}` changeset."
  def save_ingestion_config(%Ecto.Changeset{valid?: true} = changeset) do
    config = Ecto.Changeset.apply_changes(changeset)

    Enum.each(@ingestion_fields, fn field ->
      value = Map.get(config, String.to_existing_atom(field))
      set_config("ingestion.#{field}", value)
    end)

    apply_ingestion_to_app_env()
    {:ok, get_ingestion_config()}
  end

  def save_ingestion_config(%Ecto.Changeset{valid?: false} = changeset), do: {:error, changeset}

  # ── Helpers ───────────────────────────────────────────────────────────

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

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

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp blank_to_nil(value) do
    if blank?(value), do: nil, else: value
  end

  defp normalize_tls_mode("enabled"), do: :if_available
  defp normalize_tls_mode("if_available"), do: :if_available
  defp normalize_tls_mode("always"), do: :always
  defp normalize_tls_mode("never"), do: :never
  defp normalize_tls_mode(_), do: :if_available

  defp normalize_tls_verify_mode("verify_none"), do: :verify_none
  defp normalize_tls_verify_mode(_), do: :verify_peer

  defp transport_settings(%EmailConfig{transport_mode: "ssl"}), do: {true, :never}
  defp transport_settings(%EmailConfig{} = cfg), do: {false, normalize_tls_mode(cfg.tls)}

  defp smtp_tls_options(%EmailConfig{} = cfg) do
    verify = normalize_tls_verify_mode(cfg.tls_verify)
    relay = String.trim(cfg.relay)

    options =
      [
        versions: [:"tlsv1.2", :"tlsv1.3"],
        verify: verify,
        depth: 4,
        server_name_indication: to_charlist(relay)
      ]

    cond do
      verify == :verify_none ->
        options

      not blank?(cfg.ca_cert_path) ->
        options ++ [cacertfile: to_charlist(cfg.ca_cert_path)]

      true ->
        options ++ [cacerts: default_cacerts()]
    end
  end

  defp default_cacerts do
    :public_key.cacerts_get()
    |> Enum.map(fn
      {:cert, der, _} -> der
      der when is_binary(der) -> der
    end)
  rescue
    _ -> []
  end

  defp decrypt_password_value(value) do
    case EncryptedString.decrypt(value) do
      {:ok, decrypted} -> decrypted
      {:error, _reason} -> nil
    end
  end

  defp password_for_delivery(%EmailConfig{username: username}) when username in [nil, ""] do
    {:ok, ""}
  end

  defp password_for_delivery(%EmailConfig{}) do
    case EncryptedString.decrypt(get_config("email.password")) do
      {:ok, nil} -> {:ok, ""}
      {:ok, password} -> {:ok, password}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_delivery_opts(%EmailConfig{} = cfg, password) do
    auth = if blank?(cfg.username), do: :never, else: :always
    {ssl, tls} = transport_settings(cfg)

    tls_options =
      if ssl or tls != :never do
        smtp_tls_options(cfg)
      else
        []
      end

    opts =
      [
        adapter: Swoosh.Adapters.SMTP,
        relay: String.trim(cfg.relay),
        port: cfg.port,
        ssl: ssl,
        tls: tls,
        tls_options: tls_options,
        auth: auth
      ]

    if blank?(cfg.username),
      do: opts,
      else: opts ++ [username: cfg.username, password: password]
  end

  defp persist_email_fields(config) do
    Enum.reduce_while(@email_fields, :ok, fn field, :ok ->
      value = Map.get(config, String.to_existing_atom(field))

      result =
        case field do
          "password" -> persist_encrypted_password(value)
          _ -> set_config("email.#{field}", value)
        end

      case result do
        {:ok, _row} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp persist_encrypted_password(value) when value in [nil, ""] do
    set_config("email.password", value)
  end

  defp persist_encrypted_password(value) when is_binary(value) do
    with {:ok, encrypted} <- EncryptedString.encrypt(value) do
      set_config("email.password", encrypted)
    end
  end

  defp maybe_reload_telemetry_collector do
    if Process.whereis(Collector) do
      Collector.reload_policy()
    end

    :ok
  end

  defp apply_llm_to_app_env do
    cfg = get_llm_config()
    current = Application.get_env(:zaq, Zaq.Agent.LLM, [])

    Application.put_env(
      :zaq,
      Zaq.Agent.LLM,
      Keyword.merge(current,
        endpoint: cfg.endpoint,
        api_key: cfg.api_key,
        model: cfg.model,
        temperature: cfg.temperature,
        top_p: cfg.top_p,
        supports_logprobs: cfg.supports_logprobs,
        supports_json_mode: cfg.supports_json_mode
      )
    )
  end

  defp apply_embedding_to_app_env do
    cfg = get_embedding_config()
    current = Application.get_env(:zaq, Zaq.Embedding.Client, [])

    Application.put_env(
      :zaq,
      Zaq.Embedding.Client,
      Keyword.merge(current,
        endpoint: cfg.endpoint,
        api_key: cfg.api_key,
        model: cfg.model,
        dimension: cfg.dimension
      )
    )
  end

  defp apply_image_to_text_to_app_env do
    cfg = get_image_to_text_config()
    current = Application.get_env(:zaq, Zaq.Ingestion.Python.Steps.ImageToText, [])

    Application.put_env(
      :zaq,
      Zaq.Ingestion.Python.Steps.ImageToText,
      Keyword.merge(current,
        api_url: cfg.api_url,
        api_key: cfg.api_key,
        model: cfg.model
      )
    )
  end

  defp apply_ingestion_to_app_env do
    cfg = get_ingestion_config()
    current = Application.get_env(:zaq, Zaq.Ingestion, [])

    Application.put_env(
      :zaq,
      Zaq.Ingestion,
      Keyword.merge(current,
        max_context_window: cfg.max_context_window,
        distance_threshold: cfg.distance_threshold,
        hybrid_search_limit: cfg.hybrid_search_limit,
        chunk_min_tokens: cfg.chunk_min_tokens,
        chunk_max_tokens: cfg.chunk_max_tokens,
        base_path: cfg.base_path
      )
    )
  end

  defp raw_or(raw_val, app_val, default), do: raw_val || app_val || default

  defp encrypt_api_key(value) when is_binary(value) and value != "" do
    case EncryptedString.encrypt(value) do
      {:ok, encrypted} -> encrypted
      {:error, _} -> value
    end
  end

  defp decrypt_api_key(nil), do: nil
  defp decrypt_api_key(""), do: nil

  defp decrypt_api_key(value) when is_binary(value) do
    case EncryptedString.decrypt(value) do
      {:ok, "••••••••"} -> nil
      {:ok, decrypted} -> decrypted
      {:error, _} -> nil
    end
  end
end
