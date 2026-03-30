defmodule ZaqWeb.Live.BO.Communication.NotificationSmtpLive do
  use ZaqWeb, :live_view

  alias Zaq.Mailer
  alias Zaq.System
  alias Zaq.System.EmailConfig
  alias ZaqWeb.ChangesetErrors

  @impl true
  def mount(_params, _session, socket) do
    config = System.get_email_config()
    changeset = EmailConfig.changeset(config, %{})

    {:ok,
     socket
     |> assign(:current_path, "/bo/channels/notifications/email/smtp")
     |> assign(:page_title, "SMTP Configuration")
     |> assign(:form, to_form(changeset))
     |> assign(:smtp_warnings, smtp_warnings(changeset))
     |> assign(:email_enabled, config.enabled)
     |> assign(:save_status, :idle)
     |> assign(:test_status, :idle)
     |> assign(:test_recipient, "")}
  end

  @impl true
  def handle_params(%{"type" => type}, _uri, socket) do
    {:noreply, assign(socket, :current_path, "/bo/channels/notifications/email/#{type}")}
  end

  @impl true
  def handle_event("validate", %{"email_config" => params}, socket) do
    config = System.get_email_config()

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
    config = System.get_email_config()
    # Preserve the current enabled state — it's controlled by activate/deactivate
    params_with_enabled = Map.put(params, "enabled", to_string(config.enabled))
    changeset = EmailConfig.changeset(config, params_with_enabled)

    case System.save_email_config(changeset) do
      {:ok, _} ->
        fresh_config = System.get_email_config()
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
    config = System.get_email_config()
    new_enabled = !config.enabled
    changeset = EmailConfig.changeset(config, %{"enabled" => to_string(new_enabled)})

    case System.save_email_config(changeset) do
      {:ok, _} ->
        fresh_config = System.get_email_config()
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
        send(self(), {:send_test, recipient})
        {:noreply, assign(socket, :test_status, :loading)}
    end
  end

  @impl true
  def handle_event("test_connection", _params, socket) do
    {:noreply, assign(socket, :test_status, {:error, "Enter a recipient email to send a test."})}
  end

  @impl true
  def handle_info({:send_test, recipient}, socket) do
    result =
      try do
        case System.email_delivery_opts() do
          {:error, :not_configured} ->
            {:error, "Email is not configured or disabled."}

          {:ok, delivery_opts} ->
            {from_name, from_email} = System.email_sender()

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

    test_status =
      case result do
        :ok -> :ok
        {:error, msg} -> {:error, msg}
      end

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
end
