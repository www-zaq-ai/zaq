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
  alias Zaq.System.SecretConfig
  alias Zaq.System.TelemetryConfig

  @email_fields ~w(
    enabled relay port transport_mode tls tls_verify ca_cert_path username password from_email from_name
  )
  @telemetry_fields ~w(capture_infra_metrics request_duration_threshold_ms repo_query_duration_threshold_ms)

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
    case Repo.get_by(Config, key: key) do
      nil -> %Config{}
      row -> row
    end
    |> Config.changeset(%{key: key, value: to_string(value)})
    |> Repo.insert_or_update()
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

  SMTP password values are encrypted at rest via `Zaq.System.SecretConfig`.
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
      repo_query_duration_threshold_ms: parse_int(raw["repo_query_duration_threshold_ms"], 5)
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

  # ── Helpers ───────────────────────────────────────────────────────────

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

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

    options =
      [
        verify: verify,
        server_name_indication: to_charlist(cfg.relay)
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
    case :public_key.cacerts_get() do
      certs when is_list(certs) -> certs
      _ -> []
    end
  rescue
    _ -> []
  end

  defp decrypt_password_value(value) do
    case SecretConfig.decrypt(value) do
      {:ok, decrypted} -> decrypted
      {:error, _reason} -> nil
    end
  end

  defp password_for_delivery(%EmailConfig{username: username}) when username in [nil, ""] do
    {:ok, ""}
  end

  defp password_for_delivery(%EmailConfig{}) do
    case SecretConfig.decrypt(get_config("email.password")) do
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
        relay: cfg.relay,
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
    with {:ok, encrypted} <- SecretConfig.encrypt(value) do
      set_config("email.password", encrypted)
    end
  end

  defp maybe_reload_telemetry_collector do
    if Process.whereis(Collector) do
      Collector.reload_policy()
    end

    :ok
  end
end
