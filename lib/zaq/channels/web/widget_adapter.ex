defmodule Zaq.Channels.Web.WidgetAdapter do
  @moduledoc """
  Server-side contract for an externally installed web widget adapter.

  The trusted `:web_widget` runtime builder implements these callbacks. ZAQ
  owns connector configuration and the fixed ingress sink; the adapter owns
  its endpoint, sender verification, origin policy and browser transport.
  Installation markup is returned as text for administrators to copy, never
  executed in BO. It must not contain authentication secrets.
  """

  @type runtime_specs :: {map() | nil, [map()]}

  @doc "Builds supervised runtime specs using resolved server configuration and fixed hooks."
  @callback build(map(), map()) :: {:ok, runtime_specs()} | {:error, term()}

  @doc "Builds installation markup from the connector ID and global ZAQ base URL."
  @callback embed_script(pos_integer(), String.t()) :: {:ok, String.t()} | {:error, term()}

  @doc "Reports bounded, secret-free installed readiness under the WebBridge status contract."
  @callback status(pos_integer(), keyword()) ::
              {:ok, map()} | {:error, :invalid_request | :check_timeout | :check_failed}

  @optional_callbacks status: 2
end
