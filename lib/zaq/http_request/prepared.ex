defmodule Zaq.HttpRequest.Prepared do
  @moduledoc """
  Engine-prepared outbound HTTP execution contract.

  Engine owns database-backed policy and credential loading. Channels receives
  this value only as an internal return from Engine preparation, then performs
  DNS/address validation and the network request.
  """

  alias Zaq.System.OutboundHttpPolicy

  @type rendered_credential ::
          nil
          | {:header, String.t(), String.t()}
          | {:auth, {:basic, String.t()}}
          | {:query, String.t(), String.t()}

  @type t :: %__MODULE__{
          method: String.t(),
          url: String.t(),
          uri: URI.t(),
          headers: %{String.t() => String.t()},
          query: %{String.t() => String.t()},
          body: term(),
          body_format: String.t(),
          timeout_ms: pos_integer(),
          doc_reference: String.t(),
          policy: OutboundHttpPolicy.t(),
          credential: rendered_credential()
        }

  @enforce_keys [
    :method,
    :url,
    :uri,
    :headers,
    :query,
    :body_format,
    :timeout_ms,
    :doc_reference,
    :policy
  ]
  defstruct [
    :method,
    :url,
    :uri,
    :body,
    :body_format,
    :timeout_ms,
    :doc_reference,
    :policy,
    headers: %{},
    query: %{},
    credential: nil
  ]

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(prepared, opts) do
      prepared
      |> Map.from_struct()
      |> Map.put(:credential, redacted(prepared.credential))
      |> concat_map(opts)
    end

    defp redacted(nil), do: nil
    defp redacted({kind, name, _value}), do: {kind, name, "[REDACTED]"}
    defp redacted({:auth, {:basic, _value}}), do: {:auth, {:basic, "[REDACTED]"}}

    defp concat_map(map, opts) do
      concat(["#Zaq.HttpRequest.Prepared<", to_doc(map, opts), ">"])
    end
  end
end
