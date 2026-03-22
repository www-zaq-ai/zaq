defmodule Zaq.Engine.Notifications.Adapters.EmailAdapter do
  @moduledoc """
  Email notification adapter.

  Delivers notifications via SMTP using Swoosh/Mailer.
  The recipient address comes from the `identifier` argument — it is never
  read from `ChannelConfig`. SMTP settings are read from `Zaq.System`
  (same source as the SMTP configuration UI).
  """

  @behaviour Zaq.Engine.NotificationAdapter

  import Swoosh.Email

  alias Zaq.Mailer
  alias Zaq.System

  @impl true
  def platform, do: "email"

  @impl true
  def send(identifier, payload, _metadata) do
    {from_name, from_email} = System.email_sender()

    delivery_opts =
      case System.email_delivery_opts() do
        {:ok, opts} -> opts
        {:error, :not_configured} -> []
      end

    subject = Map.get(payload, "subject", "")
    body = Map.get(payload, "body", "")
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
    |> String.split("\n")
    |> Enum.map_join("", &("<p>" <> html_escape(&1) <> "</p>"))
  end

  defp html_escape(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
