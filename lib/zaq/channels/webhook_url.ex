defmodule Zaq.Channels.WebhookUrl do
  @moduledoc """
  Builds public webhook callback URLs for channel providers.

  URLs are based on `system.global.base_url`, the canonical public base URL
  configured in System Config. When no global base URL is configured, non-bang
  builders return `nil` so callers can disable provider webhook features or
  surface a configuration error.
  """

  alias Zaq.System

  @spec build(String.t() | atom(), String.t() | atom()) :: String.t() | nil
  @doc "Builds `/channels/webhook/:type/:provider` from the global base URL."
  def build(type, provider) do
    with base when is_binary(base) and base != "" <- System.get_global_base_url(),
         type when is_binary(type) and type != "" <- normalize_segment(type),
         provider when is_binary(provider) and provider != "" <- normalize_segment(provider) do
      String.trim_trailing(base, "/") <> "/channels/webhook/#{type}/#{provider}"
    end
  end

  @spec build!(String.t() | atom(), String.t() | atom()) :: String.t()
  @doc "Builds a webhook URL or raises when global base URL is not configured."
  def build!(type, provider) do
    build(type, provider) ||
      raise ArgumentError, "global base URL is required to build webhook URL"
  end

  defp normalize_segment(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_segment(value) when is_binary(value), do: String.trim(value)
  defp normalize_segment(_value), do: nil
end
