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
  alias Zaq.Channels.SmtpHelpers
  alias Zaq.Utils.ParseUtils

  def send_notification(identifier, payload, metadata) do
    {from_name, from_email} = email_sender(payload, metadata)
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
      |> apply_custom_headers(payload, metadata)

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

  defp apply_custom_headers(email, payload, metadata) do
    headers =
      map_get(metadata, "headers") ||
        map_get(payload, "headers") ||
        %{}

    case headers do
      map when is_map(map) ->
        Enum.reduce(map, email, fn
          {key, value}, acc when is_binary(key) and is_binary(value) and value != "" ->
            header(acc, key, value)

          _, acc ->
            acc
        end)

      _ ->
        email
    end
  end

  defp html_escape(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp email_sender(payload, metadata) when is_map(payload) and is_map(metadata) do
    from_name = resolve_sender_name(payload, metadata)
    from_email = resolve_sender_email(payload, metadata)

    {normalize_name(from_name) || "ZAQ", normalize_email(from_email) || "noreply@zaq.local"}
  end

  defp resolve_sender_email(payload, metadata) do
    from_value = map_get(metadata, "from") || map_get(payload, "from")

    map_get(metadata, "from_email") ||
      map_get(payload, "from_email") ||
      from_value_email(from_value)
  end

  defp resolve_sender_name(payload, metadata) do
    from_value = map_get(metadata, "from") || map_get(payload, "from")

    map_get(metadata, "from_name") ||
      map_get(payload, "from_name") ||
      from_value_name(from_value)
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

  defp parse_int(str, default), do: ParseUtils.parse_int(str, default)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp map_get(map, key), do: SmtpHelpers.map_get(map, key)

  defp from_value_email({_, email}) when is_binary(email), do: email
  defp from_value_email(%{email: email}) when is_binary(email), do: email
  defp from_value_email(%{"email" => email}) when is_binary(email), do: email
  defp from_value_email(%{address: email}) when is_binary(email), do: email
  defp from_value_email(%{"address" => email}) when is_binary(email), do: email
  defp from_value_email(email) when is_binary(email), do: email
  defp from_value_email(_), do: nil

  defp from_value_name({name, _}) when is_binary(name), do: name
  defp from_value_name(%{name: name}) when is_binary(name), do: name
  defp from_value_name(%{"name" => name}) when is_binary(name), do: name
  defp from_value_name(_), do: nil

  defp normalize_email(nil), do: nil

  defp normalize_email(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_email(_), do: nil

  defp normalize_name(nil), do: nil

  defp normalize_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_name(_), do: nil
end
