defmodule Zaq.Channels.MessageFormatter do
  @moduledoc """
  Channel-aware outbound message formatting at the Channels API boundary.

  This module is a Channels concern and is applied by `Zaq.Channels.Api` before
  delegating to provider bridges (`send_reply/2`, `upsert_message/3`).

  Source message bodies are expected to be markdown. Per-provider output format
  is configured under `config :zaq, :channels` with `:message_format`:

      config :zaq, :channels, %{
        mattermost: %{bridge: Zaq.Channels.JidoChatBridge},
        email: %{bridge: Zaq.Channels.EmailBridge, message_format: :html},
        web: %{bridge: Zaq.Channels.WebBridge, message_format: :plain_text}
      }

  Supported values:

  - `nil` / unset / `:none`: no transformation
  - `:plain_text`: markdown -> html (`Earmark`) -> plain text
  - `:html`: markdown -> html (`Earmark`)

  Notes:

  - Sanitization is intentionally not applied in this module for now.
  - If channel HTML sanitization is needed, add it in this formatter's markdown
    to HTML step so all channel bridges stay aligned.

  On formatting errors, the original body is kept unchanged.

  `format_outgoing/1` is the canonical public entrypoint.
  """

  alias Zaq.Channels.Bridge
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Utils.HtmlUtils

  @doc """
  Formats an outbound message body according to provider `:message_format`
  channel config while preserving all routing and metadata fields.
  """
  @spec format_outgoing(Outgoing.t()) :: Outgoing.t()
  def format_outgoing(%Outgoing{} = outgoing) do
    provider_config = provider_channel_config(outgoing.provider)
    format = provider_message_format(provider_config)
    formatter = provider_message_formatter(provider_config)
    metadata = ensure_metadata_map(outgoing.metadata)

    body =
      case outgoing.body do
        text when is_binary(text) -> format_text(text, format, formatter)
        other -> other
      end

    %{outgoing | body: body, metadata: put_format_metadata(metadata, format)}
  end

  defp provider_channel_config(provider) do
    key =
      cond do
        is_atom(provider) -> provider
        is_binary(provider) -> Bridge.provider_to_bridge_key(provider)
        true -> nil
      end

    Application.get_env(:zaq, :channels, %{})
    |> Map.get(key, %{})
  end

  defp provider_message_format(provider_config) when is_map(provider_config),
    do: provider_config |> Map.get(:message_format) |> normalize_format()

  defp provider_message_format(_provider_config), do: nil

  defp provider_message_formatter(provider_config) when is_map(provider_config),
    do: Map.get(provider_config, :message_formatter)

  defp provider_message_formatter(_provider_config), do: nil

  defp normalize_format(format) when format in [nil, "", :none], do: nil

  defp normalize_format(format) when is_binary(format) do
    String.to_existing_atom(format)
  rescue
    ArgumentError -> nil
  end

  defp normalize_format(format), do: format

  defp format_text(text, _format, {module, function})
       when is_atom(module) and is_atom(function) do
    apply(module, function, [text])
  rescue
    _error -> text
  end

  defp format_text(text, nil, _formatter), do: text

  defp format_text(text, :plain_text, _formatter) do
    case markdown_to_html(text) do
      {:ok, html} -> HtmlUtils.html_to_text(html)
      {:error, _reason} -> text
    end
  end

  defp format_text(text, :html, _formatter) do
    case markdown_to_html(text) do
      {:ok, html} -> html
      {:error, _reason} -> text
    end
  end

  defp format_text(text, _unknown_format, _formatter), do: text

  defp ensure_metadata_map(metadata) when is_map(metadata), do: metadata
  defp ensure_metadata_map(_metadata), do: %{}

  defp put_format_metadata(metadata, format) when format in [:html, :plain_text] do
    metadata
    |> Map.delete("format")
    |> Map.put(:format, format)
  end

  defp put_format_metadata(metadata, _format) do
    metadata
    |> Map.delete(:format)
    |> Map.delete("format")
  end

  defp markdown_to_html(text) when is_binary(text) do
    case Earmark.as_html(text, escape: true, breaks: true) do
      {:ok, html, _messages} when is_binary(html) -> {:ok, html}
      {:error, _html, _messages} = error -> error
      other -> {:error, {:invalid_earmark_output, other}}
    end
  rescue
    error -> {:error, error}
  end
end
