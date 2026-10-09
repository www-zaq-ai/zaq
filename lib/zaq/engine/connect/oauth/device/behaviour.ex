defmodule Zaq.Engine.Connect.OAuth.Device.Behaviour do
  @moduledoc """
  Pure provider protocol for device sign-in. Connect owns HTTP, scheduling,
  authorization and persistence. Timing is supplied by provider responses/defaults,
  not inferred by the worker. No implementation may execute HTTP or write grants.
  """

  alias Zaq.Engine.Connect.Credential

  @type request :: %{
          required(:url) => String.t(),
          optional(:json) => map(),
          optional(:form) => map()
        }
  @callback initiate_request(Credential.t()) :: request()
  @callback initiate_response(integer(), term()) :: {:ok, map()} | {:error, :oauth_failed}
  @callback poll_request(Credential.t(), map()) :: request()
  @callback poll_response(integer(), term(), pos_integer()) ::
              {:pending, pos_integer()}
              | {:exchange, map()}
              | {:approved, map()}
              | {:terminal, :denied | :expired | :failed}
  @callback exchange_request(Credential.t(), map()) :: request()
end
