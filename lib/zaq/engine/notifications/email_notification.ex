defmodule Zaq.Engine.Notifications.EmailNotification do
  @moduledoc """
  Email notification delivery.

  Delivers notifications via SMTP using Swoosh/Mailer. The recipient address
  comes from the `identifier` argument. SMTP settings are read from
  `channel_configs.settings` under provider `email:smtp` (same source as the
  SMTP configuration UI).
  """

  import Swoosh.Email

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Mailer
  alias Zaq.Types.EncryptedString

  @smtp_provider "email:smtp"
  @setting_atom_keys %{
    "relay" => :relay,
    "port" => :port,
    "transport_mode" => :transport_mode,
    "tls" => :tls,
    "tls_verify" => :tls_verify,
    "ca_cert_path" => :ca_cert_path,
    "username" => :username,
    "password" => :password,
    "from_email" => :from_email,
    "from_name" => :from_name
  }

  def send_notification(identifier, payload, metadata) do
    {from_name, from_email} = email_sender()
    delivery_opts = email_delivery_opts()

    subject = Map.get(payload, "subject", "")
    body = Map.get(metadata, "email_body") || Map.get(payload, "body", "")
    html = Map.get(payload, "html_body") || text_to_html(body)

    email =
      new()
      |> to(identifier)
      |> from({from_name, from_email})
      |> subject(subject)
      |> text_body(body)
      |> html_body(html)

    case Mailer.deliver(email, delivery_opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp text_to_html(text) do
    text
    |> String.split("\n\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.map_join("", fn paragraph ->
      lines = paragraph |> String.split("\n") |> Enum.map(&html_escape/1)
      "<p>" <> Enum.join(lines, "<br>") <> "</p>"
    end)
  end

  defp html_escape(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp email_sender do
    settings = smtp_settings()

    {map_get(settings, "from_name") || "ZAQ",
     map_get(settings, "from_email") || "noreply@zaq.local"}
  end

  defp email_delivery_opts do
    case ChannelConfig.get_by_provider(@smtp_provider) do
      nil -> []
      %ChannelConfig{settings: settings} -> build_delivery_opts_from_settings(settings)
    end
  end

  defp build_delivery_opts_from_settings(settings) do
    relay = map_get(settings, "relay")
    username = map_get(settings, "username")

    if blank?(relay) do
      []
    else
      password = decrypted_password(settings, username)
      auth = if blank?(username), do: :never, else: :always

      {ssl, tls} =
        transport_settings(map_get(settings, "transport_mode"), map_get(settings, "tls"))

      opts = [
        adapter: Swoosh.Adapters.SMTP,
        relay: String.trim(relay),
        port: parse_int(map_get(settings, "port"), 587),
        ssl: ssl,
        tls: tls,
        tls_options:
          smtp_tls_options(
            relay,
            map_get(settings, "tls_verify"),
            map_get(settings, "ca_cert_path"),
            ssl,
            tls
          ),
        auth: auth
      ]

      if blank?(username), do: opts, else: opts ++ [username: username, password: password]
    end
  end

  defp decrypted_password(_settings, username) when username in [nil, ""], do: ""

  defp decrypted_password(settings, _username) do
    case EncryptedString.decrypt(map_get(settings, "password")) do
      {:ok, password} when is_binary(password) -> password
      _ -> ""
    end
  end

  defp transport_settings("ssl", _tls), do: {true, :never}
  defp transport_settings(_mode, tls), do: {false, normalize_tls_mode(tls)}

  defp normalize_tls_mode("always"), do: :always
  defp normalize_tls_mode("never"), do: :never
  defp normalize_tls_mode("enabled"), do: :if_available
  defp normalize_tls_mode("if_available"), do: :if_available
  defp normalize_tls_mode(_), do: :if_available

  defp smtp_tls_options(_relay, _verify, _ca_cert_path, false, :never), do: []

  defp smtp_tls_options(relay, tls_verify, ca_cert_path, _ssl, _tls) do
    verify = if tls_verify == "verify_none", do: :verify_none, else: :verify_peer

    options = [
      versions: [:"tlsv1.2", :"tlsv1.3"],
      verify: verify,
      depth: 4,
      server_name_indication: to_charlist(String.trim(relay))
    ]

    cond do
      verify == :verify_none ->
        options

      blank?(ca_cert_path) ->
        options ++ [cacerts: default_cacerts()]

      true ->
        options ++ [cacertfile: to_charlist(ca_cert_path)]
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

  defp smtp_settings do
    case ChannelConfig.get_by_provider(@smtp_provider) do
      %ChannelConfig{settings: settings} when is_map(settings) -> settings
      _ -> %{}
    end
  end

  defp map_get(map, key) when is_map(map) do
    atom_key = Map.get(@setting_atom_keys, key)
    if atom_key, do: Map.get(map, key) || Map.get(map, atom_key), else: Map.get(map, key)
  end
end
