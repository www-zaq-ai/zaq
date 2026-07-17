defmodule Zaq.Channels.EmailBridge.SmtpSender do
  @moduledoc """
  SMTP delivery for the email channel.

  Delivers a channel payload via SMTP using Swoosh/Mailer. The recipient address
  comes from the `recipient` argument. SMTP settings are read from
  `channel_configs.settings` under provider `email:smtp` (same source as the
  SMTP configuration UI).

  This is the email channel's own delivery mechanism — it lives in the Channels
  layer so that SMTP knowledge (relay, TLS, headers, sender resolution) never
  leaks into the Engine.
  """

  import Swoosh.Email
  import Zaq.Helpers, only: [blank?: 1]

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.SmtpHelpers
  alias Zaq.Mailer
  alias Zaq.Types.EncryptedString
  alias Zaq.Utils.HtmlUtils
  alias Zaq.Utils.ParseUtils

  @smtp_provider "email:smtp"

  @doc """
  Delivers `payload` to `recipient` over SMTP.

  `payload` carries `"subject"`, `"body"`, `"html_body"`, `"format"`, `"headers"`,
  and optional sender overrides (`"from_email"`, `"from_name"`, `"reply_from_email"`).
  `metadata` may carry an `"email_body"` override and additional `"headers"`.
  """
  @spec deliver(String.t(), map(), map()) :: :ok | {:error, term()}
  def deliver(recipient, payload, metadata \\ %{}) do
    settings = smtp_settings()
    {from_name, from_email} = email_sender(payload, metadata, settings)
    delivery_opts = build_delivery_opts_from_settings(settings)

    subject = Map.get(payload, "subject", "")
    body = Map.get(metadata, "email_body") || Map.get(payload, "body", "")
    format = Map.get(payload, "format")
    {text, html} = resolve_email_bodies(body, Map.get(payload, "html_body"), format)

    email =
      new()
      |> to(recipient)
      |> from({from_name, from_email})
      |> subject(subject)
      |> text_body(text)
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

  defp resolve_email_bodies(body, html_body, format) do
    case normalize_format(format) do
      :html ->
        html = html_body || body || ""
        {HtmlUtils.html_to_text(html), html}

      _ ->
        text = body || ""
        {text, html_body || text_to_html(text)}
    end
  end

  defp normalize_format(value) when value in [:html, "html"], do: :html
  defp normalize_format(_value), do: nil

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

  defp email_sender(payload, metadata, settings)
       when is_map(payload) and is_map(metadata) and is_map(settings) do
    from_name =
      normalize_name(resolve_sender_name(payload, metadata)) ||
        normalize_name(map_get(settings, "from_name"))

    # An explicitly requested sender wins, then the configured From Email, then
    # the address the original mail was delivered to (replies only).
    from_email =
      normalize_email(resolve_sender_email(payload, metadata)) ||
        normalize_email(map_get(settings, "from_email")) ||
        normalize_email(map_get(payload, "reply_from_email"))

    {from_name || "ZAQ", from_email || "noreply@zaq.local"}
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

  defp smtp_settings do
    case ChannelConfig.get_by_provider(@smtp_provider) do
      %ChannelConfig{settings: settings} when is_map(settings) -> settings
      _ -> %{}
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
