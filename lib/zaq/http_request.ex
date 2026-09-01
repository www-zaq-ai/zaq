defmodule Zaq.HttpRequest do
  @moduledoc """
  A validated outbound HTTP request spec.

  This struct is the boundary type between *deciding what to send* and
  *sending it*. The channels node revalidates the plain request map before
  opening a socket, so a forged struct cannot bypass policy.

  It lives at the top level, alongside `Zaq.Event`, because it crosses roles.
  The channels node treats the struct as untrusted and reruns policy checks
  before transport.

  `build/2` delegates to `Zaq.HttpRequest.Validator`, using an enabled structural
  policy so tool-facing normalization matches runtime validation.

  ## Credentials

  The request may carry `credential_id`, which references a BO-managed Auth
  Credential. The plaintext secret is resolved only by `Zaq.Channels.HttpClient`
  immediately before transport. Literal `authorization` and
  `proxy-authorization` headers are still rejected because they would put
  secrets in the model context.

  DNS/IP enforcement runs on the channels node. Private and special-use ranges
  are blocked by default, including loopback, link-local, cloud metadata,
  carrier-grade NAT, multicast, unspecified, reserved, and IPv6 unique-local
  destinations.
  """

  alias Zaq.HttpRequest.Validator
  alias Zaq.System.OutboundHttpPolicy

  @default_timeout_ms 30_000

  @type t :: %__MODULE__{
          method: atom(),
          url: String.t(),
          headers: %{String.t() => String.t()},
          query: %{String.t() => String.t()},
          body: term(),
          body_format: String.t(),
          timeout_ms: pos_integer(),
          doc_reference: String.t(),
          credential_id: pos_integer() | nil
        }

  defstruct method: :get,
            url: nil,
            headers: %{},
            query: %{},
            body: nil,
            body_format: "json",
            timeout_ms: @default_timeout_ms,
            doc_reference: "",
            credential_id: nil

  @doc """
  Validates `params` and returns the request spec.

  `params` is the `http_request` tool parameter map: `method`, `url`,
  `headers`, `query`, `body`, `body_format`, `timeout_ms`, and
  `doc_reference`. Errors are returned as sentences addressed to the model,
  since they are fed back to it as the tool result.
  """
  @spec build(map(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def build(params, opts \\ []) when is_map(params) and is_list(opts) do
    policy = Keyword.get(opts, :policy, build_policy())

    case Validator.validate(params, policy) do
      {:ok, request} ->
        method = request.method |> String.downcase() |> String.to_atom()

        {:ok,
         %__MODULE__{
           method: method,
           url: request.url,
           headers: request.headers,
           query: request.query,
           body: request.body,
           body_format: request.body_format,
           timeout_ms: request.timeout_ms,
           doc_reference: request.doc_reference,
           credential_id: request.credential_id
         }}

      {:error, _reason, message} ->
        {:error, message}
    end
  end

  defp build_policy do
    %OutboundHttpPolicy{
      enabled: true,
      allowed_methods: OutboundHttpPolicy.supported_methods(),
      max_timeout_ms: 120_000
    }
  end

  @doc "Returns the request as plain params for shared validation."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = request) do
    %{
      method: request.method |> Atom.to_string() |> String.upcase(),
      url: request.url,
      headers: request.headers,
      query: request.query,
      body: request.body,
      body_format: request.body_format,
      timeout_ms: request.timeout_ms,
      doc_reference: request.doc_reference,
      credential_id: request.credential_id
    }
  end
end
