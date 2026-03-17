defmodule Zaq.System do
  @moduledoc """
  Context for persistent system configuration stored in the database.
  Replaces environment-variable-based configuration for settings that should
  be managed at runtime from the back office.
  """

  import Ecto.Query

  alias Zaq.Repo
  alias Zaq.System.Config
  alias Zaq.System.EmailConfig

  @email_fields ~w(enabled relay port tls username password from_email from_name)

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

  @doc "Loads the email config from DB and returns an `%EmailConfig{}` struct."
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
      tls: raw["tls"] || "enabled",
      username: raw["username"],
      password: raw["password"],
      from_email: raw["from_email"] || "noreply@zaq.local",
      from_name: raw["from_name"] || "ZAQ"
    }
  end

  @doc "Persists email config from a validated `%EmailConfig{}` changeset."
  def save_email_config(%Ecto.Changeset{valid?: true} = changeset) do
    config = Ecto.Changeset.apply_changes(changeset)

    Enum.each(@email_fields, fn field ->
      value = Map.get(config, String.to_existing_atom(field))
      set_config("email.#{field}", value)
    end)

    {:ok, config}
  end

  def save_email_config(%Ecto.Changeset{valid?: false} = changeset), do: {:error, changeset}

  @doc """
  Returns `{:ok, keyword_list}` with Swoosh SMTP delivery options built from
  the DB config, or `{:error, :not_configured}` when email is disabled or the
  relay is not set.
  """
  def email_delivery_opts do
    cfg = get_email_config()

    if cfg.enabled and not blank?(cfg.relay) do
      auth = if blank?(cfg.username), do: :never, else: :always

      opts =
        [
          adapter: Swoosh.Adapters.SMTP,
          relay: cfg.relay,
          port: cfg.port,
          tls: String.to_atom(cfg.tls),
          auth: auth
        ]

      opts =
        if blank?(cfg.username),
          do: opts,
          else: opts ++ [username: cfg.username, password: cfg.password || ""]

      {:ok, opts}
    else
      {:error, :not_configured}
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

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
