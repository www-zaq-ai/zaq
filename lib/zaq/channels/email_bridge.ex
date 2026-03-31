defmodule Zaq.Channels.EmailBridge do
  @moduledoc """
  Bridge for the email channel.

  Delivers `%Outgoing{}` via SMTP using Swoosh. Connection details are not
  required — SMTP settings are read from `Zaq.System` (same source as the
  SMTP configuration UI).

  `to_internal/2` is a stub for future inbound email parsing.
  """

  alias Zaq.Engine.Messages.Outgoing

  @doc "Stub for future inbound email parsing — not yet implemented."
  @spec to_internal(map(), map()) :: {:error, :not_implemented}
  def to_internal(_params, _connection_details), do: {:error, :not_implemented}

  @doc """
  Delivers `%Outgoing{}` as an email to `outgoing.channel_id` (the recipient address).

  Reads subject and html_body from `outgoing.metadata` (keys `:subject` / `"subject"`
  and `:html_body` / `"html_body"`). Falls back to a default subject if missing.
  """
  @spec send_reply(Outgoing.t(), map()) :: :ok | {:error, term()}
  def send_reply(%Outgoing{} = outgoing, _connection_details) do
    import Swoosh.Email

    alias Zaq.Mailer
    alias Zaq.System

    {from_name, from_email} = System.email_sender()

    delivery_opts =
      case System.email_delivery_opts() do
        {:ok, opts} -> opts
        {:error, :not_configured} -> []
      end

    subject = get_meta(outgoing.metadata, "subject", :subject) || "Notification from ZAQ"
    html_body = get_meta(outgoing.metadata, "html_body", :html_body)
    html = html_body || text_to_html(outgoing.body)

    email =
      new()
      |> to(outgoing.channel_id)
      |> from({from_name, from_email})
      |> subject(subject)
      |> text_body(outgoing.body)
      |> html_body(html)

    case Mailer.deliver(email, delivery_opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Handles both atom and string-keyed metadata (Oban args arrive as string keys).
  defp get_meta(metadata, string_key, atom_key) do
    Map.get(metadata, atom_key) || Map.get(metadata, string_key)
  end

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
end
