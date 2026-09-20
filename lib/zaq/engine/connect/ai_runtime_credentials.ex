defmodule Zaq.Engine.Connect.AIRuntimeCredentials do
  @moduledoc """
  Resolves AI-provider runtime authentication inside the Engine boundary.

  The caller supplies only the persisted AI-provider configuration ID and a
  validated execution actor. This module loads the System-owned provider
  configuration, delegates canonical owner/grant selection to `Zaq.Engine.Connect`,
  and returns a secret-free provider projection alongside the ephemeral resolved
  credential.

  Results may leave Engine only in a synchronous confidential `Zaq.Event`; callers
  must never persist, serialize, or log the resolved authentication.
  """

  alias Zaq.Engine.Connect
  alias Zaq.Identity.ExecutionActor
  alias Zaq.System
  alias Zaq.System.AIProviderCredential

  @provider_fields [
    :id,
    :provider,
    :endpoint,
    :metadata,
    :sovereign,
    :connect_credential_id
  ]

  @type result ::
          {:ok,
           %{
             credential: map(),
             resolved_credential: Zaq.Engine.Connect.ResolvedCredential.t()
           }
           | nil}
          | {:error, term()}

  @doc "Resolves one persisted AI-provider configuration for an execution actor."
  @spec resolve(integer(), map(), keyword()) :: result()
  def resolve(ai_provider_credential_id, actor, opts \\ [])
      when is_integer(ai_provider_credential_id) and is_list(opts) do
    with {:ok, actor} <- ExecutionActor.validate(actor) do
      resolve_provider_configuration(ai_provider_credential_id, actor, opts)
    end
  end

  defp resolve_provider_configuration(ai_provider_credential_id, actor, opts) do
    system_module = Keyword.get(opts, :system_module, System)

    case system_module.get_ai_provider_credential(ai_provider_credential_id) do
      nil ->
        {:ok, nil}

      %AIProviderCredential{} = credential ->
        resolve_provider_authentication(credential, actor, opts)
    end
  end

  defp resolve_provider_authentication(
         %AIProviderCredential{connect_credential_id: connect_credential_id} = credential,
         actor,
         opts
       )
       when is_integer(connect_credential_id) do
    connect_module = Keyword.get(opts, :connect_module, Connect)

    with {:ok, resolved} <- connect_module.resolve_credential(connect_credential_id, actor) do
      {:ok,
       %{
         credential: Map.take(credential, @provider_fields),
         resolved_credential: resolved
       }}
    end
  end

  defp resolve_provider_authentication(%AIProviderCredential{}, _actor, _opts),
    do: {:error, %{credential_id: nil, reason: :credential_unavailable}}
end
