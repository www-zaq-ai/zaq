defmodule ZaqWeb.Live.BO.Communication.NotificationSmtpLive do
  use ZaqWeb, :live_view

  import Zaq.Helpers, only: [blank?: 1]

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.EmailBridge.TlsHelpers
  alias Zaq.Config
  alias Zaq.Mailer
  alias Zaq.Repo
  alias Zaq.System.EmailConfig
  alias Zaq.Types.EncryptedString
  alias ZaqWeb.ChangesetErrors
  alias ZaqWeb.Live.BO.Communication.EmailConnectorSelection, as: ConnectorSelection

  @smtp_provider "email:smtp"
  alias Zaq.Channels.SmtpHelpers
  alias Zaq.Utils.ParseUtils

  @impl true
  def mount(_params, _session, socket) do
    socket = ConnectorSelection.initialize(socket, @smtp_provider)
    config = current_email_config(socket)
    changeset = EmailConfig.changeset(config, %{})

    {:ok,
     socket
     |> assign(:current_path, "/bo/channels/retrieval/email/smtp")
     |> assign(:page_title, "SMTP Configuration")
     |> assign(:form, to_form(changeset))
     |> assign(:smtp_warnings, smtp_warnings(changeset))
     |> assign(:email_enabled, config.enabled)
     |> assign(:save_status, :idle)
     |> assign(:test_status, :idle)
     |> assign(:test_recipient, "")}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :current_path, "/bo/channels/retrieval/email/smtp")}
  end

  @impl true
  def handle_event("select_connector", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.configs, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Connector not found.")}

      selected ->
        socket = assign(socket, :selected_config_id, selected.id)
        config = current_email_config(socket)
        changeset = EmailConfig.changeset(config, %{})

        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> assign(:email_enabled, config.enabled)
         |> assign(:smtp_warnings, smtp_warnings(changeset))
         |> assign(:save_status, :idle)
         |> assign(:test_status, :idle)}
    end
  end

  @impl true
  def handle_event("set_default_connector", %{"id" => id}, socket) do
    with {config_id, ""} <- Integer.parse(id),
         true <- Enum.any?(socket.assigns.configs, &(&1.id == config_id)),
         {:ok, _} <- ChannelConfig.set_default_smtp_connector(config_id) do
      {:noreply, assign(socket, :configs, ChannelConfig.list_by_provider(@smtp_provider))}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Cannot designate this SMTP connector as default.")}
    end
  end

  @impl true
  def handle_event("validate", %{"email_config" => params}, socket) do
    config = current_email_config(socket)

    changeset =
      config
      |> EmailConfig.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset))
     |> assign(:smtp_warnings, smtp_warnings(changeset))
     |> assign(:save_status, :idle)}
  end

  @impl true
  def handle_event("save", %{"email_config" => params}, socket) do
    config = current_email_config(socket)
    # Preserve the current enabled state — it's controlled by activate/deactivate
    params_with_enabled = Map.put(params, "enabled", to_string(config.enabled))
    changeset = EmailConfig.changeset(config, params_with_enabled)

    case persist_email_config(
           changeset,
           selected_channel(socket),
           socket.assigns.selected_config_id
         ) do
      {:ok, _} ->
        socket = ConnectorSelection.refresh(socket, @smtp_provider)
        fresh_config = current_email_config(socket)
        fresh_changeset = EmailConfig.changeset(fresh_config, %{})

        {:noreply,
         socket
         |> assign(:save_status, :ok)
         |> assign(:email_enabled, fresh_config.enabled)
         |> assign(:form, to_form(fresh_changeset))
         |> assign(:smtp_warnings, smtp_warnings(fresh_changeset))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(Map.put(changeset, :action, :validate)))
         |> assign(:smtp_warnings, smtp_warnings(changeset))
         |> assign(:save_status, {:error, format_changeset_errors(changeset)})}

      {:error, :missing_encryption_key} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Missing SYSTEM_CONFIG_ENCRYPTION_KEY; sensitive SMTP settings cannot be saved."
         )
         |> assign(:save_status, {:error, "Missing encryption key for sensitive settings."})}

      {:error, :invalid_encryption_key} ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid SYSTEM_CONFIG_ENCRYPTION_KEY format.")
         |> assign(:save_status, {:error, "Invalid encryption key configuration."})}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to save email configuration.")
         |> assign(:save_status, {:error, inspect(reason)})}
    end
  end

  @impl true
  def handle_event("activate", _params, socket) do
    config = current_email_config(socket)
    new_enabled = !config.enabled
    changeset = EmailConfig.changeset(config, %{"enabled" => to_string(new_enabled)})

    case persist_email_config(
           changeset,
           selected_channel(socket),
           socket.assigns.selected_config_id
         ) do
      {:ok, _} ->
        socket = ConnectorSelection.refresh(socket, @smtp_provider)
        fresh_config = current_email_config(socket)
        fresh_changeset = EmailConfig.changeset(fresh_config, %{})

        {:noreply,
         socket
         |> assign(:email_enabled, fresh_config.enabled)
         |> assign(:form, to_form(fresh_changeset))
         |> assign(:smtp_warnings, smtp_warnings(fresh_changeset))
         |> assign(:save_status, :idle)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:save_status, {:error, format_changeset_errors(changeset)})}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to update email status.")
         |> assign(:save_status, {:error, inspect(reason)})}
    end
  end

  @impl true
  def handle_event("test_connection", %{"recipient" => raw_recipient}, socket) do
    recipient = String.trim(raw_recipient)
    socket = assign(socket, :test_recipient, raw_recipient)

    cond do
      recipient == "" ->
        {:noreply,
         assign(socket, :test_status, {:error, "Enter a recipient email to send a test."})}

      not valid_email?(recipient) ->
        {:noreply,
         assign(socket, :test_status, {:error, "Recipient must be a valid email address."})}

      true ->
        send(self(), {:send_test, recipient, socket.assigns.selected_config_id})
        {:noreply, assign(socket, :test_status, :loading)}
    end
  end

  @impl true
  def handle_event("test_connection", _params, socket) do
    {:noreply, assign(socket, :test_status, {:error, "Enter a recipient email to send a test."})}
  end

  @impl true
  def handle_info({:send_test, recipient}, socket) do
    if length(socket.assigns.configs) <= 1,
      do: send_selected_test(recipient, socket),
      else: {:noreply, assign(socket, :test_status, {:error, "Select an SMTP connector."})}
  end

  def handle_info({:send_test, recipient, selected_id}, socket) do
    if selected_id != socket.assigns.selected_config_id do
      {:noreply, socket}
    else
      send_selected_test(recipient, socket)
    end
  end

  defp send_selected_test(recipient, socket) do
    result =
      try do
        case email_delivery_opts(socket) do
          {:error, :not_configured} ->
            {:error, "Email is not configured or disabled."}

          {:ok, delivery_opts} ->
            {from_name, from_email} = email_sender(socket)

            email =
              Swoosh.Email.new()
              |> Swoosh.Email.to(recipient)
              |> Swoosh.Email.from({from_name, from_email})
              |> Swoosh.Email.subject("ZAQ — Email configuration test")
              |> Swoosh.Email.text_body(
                "This is a test email from your ZAQ instance. If you received this, email delivery is working correctly."
              )

            case Mailer.deliver(email, delivery_opts) do
              {:ok, _} -> :ok
              {:error, reason} -> {:error, format_email_error(reason)}
            end
        end
      rescue
        exception -> {:error, Exception.message(exception)}
      end

    test_status = result

    {:noreply, assign(socket, :test_status, test_status)}
  end

  defp format_changeset_errors(changeset) do
    ChangesetErrors.format(changeset, field_separator: " ")
  end

  defp format_email_error(reason) when is_binary(reason), do: reason

  defp format_email_error({:retries_exceeded, reason}) do
    retries_reason = format_retries_reason(reason)

    case reason do
      {:missing_requirement, _host, :auth} ->
        "SMTP authentication is unavailable. This usually means TLS negotiation failed before AUTH was offered. #{retries_reason}"

      {:missing_requirement, _host, :tls} ->
        "SMTP server requires TLS but TLS could not be established. #{retries_reason}"

      _ ->
        "Could not reach the SMTP server. #{retries_reason}"
    end
  end

  defp format_email_error({:network_failure, _}),
    do: "Network error while contacting the SMTP server."

  defp format_email_error({:temporary_failure, :tls_failed}),
    do: "TLS handshake failed. Check TLS verification mode or CA certificate path."

  defp format_email_error({:error, :missing_encryption_key}),
    do: "Missing SYSTEM_CONFIG_ENCRYPTION_KEY; cannot decrypt SMTP password."

  defp format_email_error({:error, :invalid_encryption_key}),
    do: "Invalid SYSTEM_CONFIG_ENCRYPTION_KEY; cannot decrypt SMTP password."

  defp format_email_error({:error, :invalid_ciphertext}),
    do:
      "Stored SMTP password cannot be decrypted. Please re-save the password with a valid encryption key."

  defp format_email_error(:invalid_ciphertext),
    do:
      "Stored SMTP password cannot be decrypted. Please re-save the password with a valid encryption key."

  defp format_email_error(:missing_encryption_key),
    do: "Missing SYSTEM_CONFIG_ENCRYPTION_KEY; cannot decrypt SMTP password."

  defp format_email_error(:invalid_encryption_key),
    do: "Invalid SYSTEM_CONFIG_ENCRYPTION_KEY; cannot decrypt SMTP password."

  defp format_email_error(reason), do: inspect(reason)

  defp format_retries_reason(nil), do: ""

  defp format_retries_reason(reason) do
    detail =
      cond do
        is_binary(reason) -> reason
        is_atom(reason) -> Atom.to_string(reason)
        true -> inspect(reason)
      end

    case detail do
      "" -> ""
      _ -> "Details: #{detail}"
    end
  end

  defp valid_email?(email), do: String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)

  defp smtp_warnings(changeset) do
    transport_mode = Ecto.Changeset.get_field(changeset, :transport_mode, "starttls")
    tls = Ecto.Changeset.get_field(changeset, :tls, "enabled")
    tls_verify = Ecto.Changeset.get_field(changeset, :tls_verify, "verify_peer")

    []
    |> maybe_add_warning(
      transport_mode == "ssl" and Ecto.Changeset.get_field(changeset, :port, 587) != 465,
      "smtp-warning-ssl-port",
      "SSL transport usually expects port 465."
    )
    |> maybe_add_warning(
      tls == "never",
      "smtp-warning-tls-never",
      "TLS is disabled. Credentials and message content can be exposed in transit."
    )
    |> maybe_add_warning(
      tls_verify == "verify_none",
      "smtp-warning-verify-none",
      "Certificate verification is disabled (verify_none). Use only in controlled environments."
    )
  end

  defp maybe_add_warning(warnings, false, _id, _message), do: warnings

  defp maybe_add_warning(warnings, true, id, message),
    do: warnings ++ [%{id: id, message: message}]

  defp selected_channel(socket),
    do: ConnectorSelection.selected_channel(socket, @smtp_provider)

  defp current_email_config(socket) do
    channel = selected_channel(socket)
    settings = if channel, do: channel.settings || %{}, else: %{}

    %EmailConfig{
      enabled: if(channel, do: channel.enabled, else: false),
      relay: map_get(settings, "relay"),
      port: parse_int(map_get(settings, "port"), 587),
      transport_mode: map_get(settings, "transport_mode") || "starttls",
      tls: map_get(settings, "tls") || "enabled",
      tls_verify: map_get(settings, "tls_verify") || "verify_peer",
      ca_cert_path: blank_to_nil(map_get(settings, "ca_cert_path")),
      username: map_get(settings, "username"),
      password: decrypt_password_value(map_get(settings, "password")),
      from_email: map_get(settings, "from_email") || "noreply@zaq.local",
      from_name: map_get(settings, "from_name") || "ZAQ"
    }
  end

  defp persist_email_config(_changeset, nil, selected_id) when not is_nil(selected_id),
    do: {:error, :connector_mismatch}

  defp persist_email_config(%Ecto.Changeset{valid?: true} = changeset, channel, _selected_id) do
    config = Ecto.Changeset.apply_changes(changeset)

    with {:ok, encrypted_password} <- encrypt_password_value(config.password) do
      attrs = %{
        name: if(channel, do: channel.name, else: "Email SMTP"),
        kind: "retrieval",
        url: "smtp://configured-in-settings",
        token: "__smtp_unused__",
        enabled: config.enabled,
        settings: %{
          "relay" => config.relay,
          "port" => to_string(config.port || 587),
          "transport_mode" => config.transport_mode,
          "tls" => config.tls,
          "tls_verify" => config.tls_verify,
          "ca_cert_path" => blank_to_nil(config.ca_cert_path),
          "username" => blank_to_nil(config.username),
          "password" => encrypted_password,
          "from_email" => config.from_email,
          "from_name" => config.from_name
        }
      }

      case channel do
        %ChannelConfig{} = selected ->
          selected |> ChannelConfig.changeset(attrs) |> Repo.update()

        nil ->
          ChannelConfig.upsert_by_provider(@smtp_provider, attrs)
      end
    end
  end

  defp persist_email_config(%Ecto.Changeset{valid?: false} = changeset, _channel, _selected_id),
    do: {:error, changeset}

  defp email_delivery_opts(socket) do
    cfg = current_email_config(socket)

    with true <- cfg.enabled and not blank?(cfg.relay),
         {:ok, password} <- password_for_delivery(cfg, socket) do
      {:ok, build_delivery_opts(cfg, password)}
    else
      false -> {:error, :not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  defp email_sender(socket) do
    cfg = current_email_config(socket)
    {cfg.from_name || "ZAQ", cfg.from_email || "noreply@zaq.local"}
  end

  defp decrypt_password_value(value) do
    case EncryptedString.decrypt(value) do
      {:ok, decrypted} -> decrypted
      {:error, _reason} -> nil
    end
  end

  defp encrypt_password_value(value) when value in [nil, ""], do: {:ok, value}

  defp encrypt_password_value(value) when is_binary(value) do
    if EncryptedString.encrypted?(value), do: {:ok, value}, else: EncryptedString.encrypt(value)
  end

  defp password_for_delivery(%EmailConfig{username: username}, _socket)
       when username in [nil, ""] do
    {:ok, ""}
  end

  defp password_for_delivery(%EmailConfig{}, socket) do
    settings =
      case selected_channel(socket) do
        %ChannelConfig{settings: map} when is_map(map) -> map
        _ -> %{}
      end

    case EncryptedString.decrypt(map_get(settings, "password")) do
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

    opts = [
      adapter: mailer_adapter(),
      relay: String.trim(cfg.relay),
      port: cfg.port,
      ssl: ssl,
      tls: tls,
      tls_options: tls_options,
      auth: auth
    ]

    if blank?(cfg.username), do: opts, else: opts ++ [username: cfg.username, password: password]
  end

  defp mailer_adapter do
    :zaq
    |> Config.get(Mailer, [])
    |> Keyword.get(:adapter, Swoosh.Adapters.SMTP)
  end

  defp transport_settings(%EmailConfig{transport_mode: "ssl"}), do: {true, :never}
  defp transport_settings(%EmailConfig{} = cfg), do: {false, normalize_tls_mode(cfg.tls)}

  defp normalize_tls_mode("enabled"), do: :if_available
  defp normalize_tls_mode("if_available"), do: :if_available
  defp normalize_tls_mode("always"), do: :always
  defp normalize_tls_mode("never"), do: :never
  defp normalize_tls_mode(_), do: :if_available

  defp smtp_tls_options(%EmailConfig{} = cfg) do
    verify = normalize_tls_verify_mode(cfg.tls_verify)
    relay = String.trim(cfg.relay)

    options = [
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
        options ++ [cacerts: TlsHelpers.default_cacerts()]
    end
  end

  defp normalize_tls_verify_mode("verify_none"), do: :verify_none
  defp normalize_tls_verify_mode(_), do: :verify_peer

  defp parse_int(str, default), do: ParseUtils.parse_int(str, default)

  defp blank_to_nil(value) do
    if blank?(value), do: nil, else: value
  end

  defp map_get(map, key), do: SmtpHelpers.map_get(map, key)
end
