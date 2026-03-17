defmodule ZaqWeb.Live.BO.System.SystemConfigLive do
  use ZaqWeb, :live_view

  alias Zaq.Mailer
  alias Zaq.System
  alias Zaq.System.EmailConfig

  def mount(_params, _session, socket) do
    config = System.get_email_config()
    changeset = EmailConfig.changeset(config, %{})

    {:ok,
     socket
     |> assign(:current_path, "/bo/system-config")
     |> assign(:page_title, "System Configuration")
     |> assign(:form, to_form(changeset))
     |> assign(:test_status, :idle)
     |> assign(:test_recipient, "")}
  end

  def handle_event("validate", %{"email_config" => params}, socket) do
    config = System.get_email_config()

    changeset =
      config
      |> EmailConfig.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"email_config" => params}, socket) do
    config = System.get_email_config()

    changeset = EmailConfig.changeset(config, params)

    case System.save_email_config(changeset) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Email configuration saved.")
         |> assign(:form, to_form(EmailConfig.changeset(System.get_email_config(), %{})))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("set_test_recipient", %{"recipient" => recipient}, socket) do
    {:noreply, assign(socket, :test_recipient, recipient)}
  end

  def handle_event("test_connection", _params, socket) do
    recipient = String.trim(socket.assigns.test_recipient)

    if recipient == "" do
      {:noreply, put_flash(socket, :error, "Enter a recipient email to send a test.")}
    else
      send(self(), {:send_test, recipient})
      {:noreply, assign(socket, :test_status, :loading)}
    end
  end

  def handle_info({:send_test, recipient}, socket) do
    result =
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
            {:error, reason} -> {:error, inspect(reason)}
          end
      end

    test_status =
      case result do
        :ok -> :ok
        {:error, msg} -> {:error, msg}
      end

    {:noreply, assign(socket, :test_status, test_status)}
  end
end
