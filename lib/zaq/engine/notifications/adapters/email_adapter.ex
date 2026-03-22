defmodule Zaq.Engine.Notifications.Adapters.EmailAdapter do
  @moduledoc """
  Email notification adapter.

  Delivers notifications via SMTP using Swoosh/Mailer.
  The recipient address comes from the `identifier` argument — it is never
  read from `ChannelConfig`. SMTP server settings are read from the
  application config (set via env vars).
  """

  @behaviour Zaq.Engine.NotificationAdapter

  import Swoosh.Email

  alias Zaq.Mailer

  @impl true
  def platform, do: "email"

  @impl true
  def send(identifier, payload, _metadata) do
    config = Application.get_env(:zaq, Zaq.Engine.Notifications, [])
    from_email = Keyword.get(config, :from_email, "noreply@zaq.local")
    from_name = Keyword.get(config, :from_name, "ZAQ")

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

    case Mailer.deliver(email) do
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
