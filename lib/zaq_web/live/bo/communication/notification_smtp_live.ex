defmodule ZaqWeb.Live.BO.Communication.NotificationSmtpLive do
  use ZaqWeb, :live_view

  import Zaq.Helpers, only: [blank?: 1]
  require Logger

  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.System.EmailConfig
  alias Zaq.Types.EncryptedString
  alias ZaqWeb.ChangesetErrors
  alias ZaqWeb.Live.BO.AI.BOActor
  alias ZaqWeb.Live.BO.Communication.EmailConnectorSelection, as: ConnectorSelection

  @smtp_provider "email:smtp"
  alias Zaq.ConnectorConfig.SmtpSettings, as: SmtpHelpers
  alias Zaq.Utils.ParseUtils

  @impl true
  def mount(_params, _session, socket) do
    {:ok, snapshot} = email_settings(socket, :snapshot, %{provider: @smtp_provider})
    socket = ConnectorSelection.initialize(socket, snapshot)
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

  def handle_event("new_connector", _params, socket) do
    socket = assign(socket, :selected_config_id, :new)
    changeset = EmailConfig.changeset(current_email_config(socket), %{})

    {:noreply,
     socket
     |> assign(:form, to_form(changeset))
     |> assign(:email_enabled, false)
     |> assign(:smtp_warnings, smtp_warnings(changeset))
     |> assign(:save_status, :idle)
     |> assign(:test_status, :idle)}
  end

  @impl true
  def handle_event("set_default_connector", %{"id" => id}, socket) do
    with {config_id, ""} <- Integer.parse(id),
         true <- Enum.any?(socket.assigns.configs, &(&1.id == config_id)),
         {:ok, snapshot} <- email_settings(socket, :set_default, %{id: config_id}) do
      {:noreply, ConnectorSelection.refresh(socket, snapshot)}
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

    case save_email_settings(socket, changeset) do
      {:ok, result} ->
        socket = ConnectorSelection.refresh(socket, result.snapshot)

        fresh_config = current_email_config(socket)
        fresh_changeset = EmailConfig.changeset(fresh_config, %{})

        {:noreply,
         socket
         |> assign(:save_status, :ok)
         |> assign(:email_enabled, fresh_config.enabled)
         |> assign(:form, to_form(fresh_changeset))
         |> assign(:smtp_warnings, smtp_warnings(fresh_changeset))
         |> maybe_put_runtime_pending(result.runtime)}

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

    case save_email_settings(socket, changeset) do
      {:ok, result} ->
        socket = ConnectorSelection.refresh(socket, result.snapshot)

        fresh_config = current_email_config(socket)
        fresh_changeset = EmailConfig.changeset(fresh_config, %{})

        {:noreply,
         socket
         |> assign(:email_enabled, fresh_config.enabled)
         |> assign(:form, to_form(fresh_changeset))
         |> assign(:smtp_warnings, smtp_warnings(fresh_changeset))
         |> assign(:save_status, :idle)
         |> maybe_put_runtime_pending(result.runtime)}

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
        cfg = current_email_config(socket)

        if cfg.enabled and not blank?(cfg.relay) do
          outgoing = %Outgoing{
            provider: @smtp_provider,
            channel_id: recipient,
            body:
              "This is a test email from your ZAQ instance. If you received this, email delivery is working correctly.",
            metadata: %{"subject" => "ZAQ — Email configuration test"},
            routing_context: test_routing_context(socket)
          }

          case outgoing
               |> Event.new(:channels, opts: [action: :deliver_outgoing])
               |> NodeRouter.dispatch() do
            %Event{response: {:ok, _receipt}} -> :ok
            %Event{response: {:error, reason}} -> {:error, format_email_error(reason)}
            _ -> {:error, "Email delivery returned an unexpected response."}
          end
        else
          {:error, "Email is not configured or disabled."}
        end
      rescue
        exception -> {:error, Exception.message(exception)}
      catch
        :exit, _reason ->
          Logger.warning("SMTP test delivery exited unexpectedly")
          {:error, "Email delivery failed unexpectedly. Check the server logs."}
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

  defp save_email_settings(_socket, %Ecto.Changeset{valid?: false} = changeset),
    do: {:error, changeset}

  defp save_email_settings(socket, %Ecto.Changeset{valid?: true} = changeset) do
    email_settings(socket, :save, %{
      provider: @smtp_provider,
      selected_config_id: socket.assigns.selected_config_id,
      params: changeset.params || %{}
    })
  end

  defp email_settings(socket, op, request) do
    event =
      Event.new(Map.put(request, :op, op), :engine,
        actor: BOActor.build(socket.assigns[:current_user]),
        opts: [action: :email_connector_settings, confidential: true]
      )

    case NodeRouter.dispatch(event) do
      %Event{response: response} -> response
      _ -> {:error, :engine_unavailable}
    end
  end

  defp maybe_put_runtime_pending(socket, :synced), do: socket

  defp maybe_put_runtime_pending(socket, {:pending, reason}) do
    put_flash(
      socket,
      :error,
      "SMTP settings saved, but runtime sync is pending: #{inspect(reason)}"
    )
  end

  defp test_routing_context(%{assigns: %{configs: configs, selected_config_id: id}})
       when length(configs) > 1 and is_integer(id),
       do: %{channel_config_id: id}

  defp test_routing_context(_socket), do: nil

  defp decrypt_password_value(value) do
    case EncryptedString.decrypt(value) do
      {:ok, decrypted} -> decrypted
      {:error, _reason} -> nil
    end
  end

  defp parse_int(str, default), do: ParseUtils.parse_int(str, default)

  defp blank_to_nil(value) do
    if blank?(value), do: nil, else: value
  end

  defp map_get(map, key), do: SmtpHelpers.map_get(map, key)
end
