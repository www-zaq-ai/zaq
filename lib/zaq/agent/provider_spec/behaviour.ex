defmodule Zaq.Agent.ProviderSpec.Behaviour do
  @moduledoc """
  Pure provider-specific translation from ZAQ runtime configuration to ReqLLM options.

  Implementations receive already-selected authentication and identity. They never
  resolve credentials, authorize actors, perform HTTP, persist state or log secrets.
  """

  @type context :: %{
          provider: atom() | String.t() | nil,
          runtime_provider: atom() | nil,
          endpoint: String.t() | nil,
          metadata: map(),
          auth_kind: String.t() | nil,
          authentication: map(),
          runtime_identity: map()
        }

  @callback reqllm_provider(atom() | String.t() | nil) :: atom()
  @callback fixed_url_provider?(atom() | String.t() | nil) :: boolean()
  @callback put_model_spec(map(), context()) :: map()
  @callback put_credential_opts(keyword(), context()) :: keyword()
  @callback default_advanced_options(map()) :: map()
end
