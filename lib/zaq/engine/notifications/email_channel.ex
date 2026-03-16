defmodule Zaq.Engine.Notifications.EmailChannel do
  @moduledoc """
  Email notification channel adapter.

  Delivers notifications to users who have an email address via Swoosh/SMTP.
  Configured via `Zaq.Engine.Notifications` application config (set from env vars).
  """

  @behaviour Zaq.Engine.NotificationChannel

  import Swoosh.Email

  alias Zaq.Mailer

  @impl true
  def available?(%{email: email}) when is_binary(email) and email != "", do: true
  def available?(_user), do: false

  @impl true
  def send_notification(user, %{subject: subject, body: body} = notification) do
    config = Application.get_env(:zaq, Zaq.Engine.Notifications, [])
    from_email = Keyword.get(config, :from_email, "noreply@zaq.local")
    from_name = Keyword.get(config, :from_name, "ZAQ")

    html = Map.get(notification, :html_body, text_to_html(body))

    email =
      new()
      |> to({user.username, user.email})
      |> from({from_name, from_email})
      |> subject(subject)
      |> text_body(body)
      |> html_body(html)

    case Mailer.deliver(email) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

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
