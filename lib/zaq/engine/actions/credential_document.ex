defmodule Zaq.Engine.Actions.CredentialDocument do
  @moduledoc """
  Validated runtime-only Action for one connector-bound encrypted document operation.

  The role API establishes the confidential synchronous hop and supplies explicit
  trusted runtime context. No BO actor, Person identity or binding ID grants that
  capability. This Action must not be exposed as an agent tool or workflow step.
  """

  use Jido.Action,
    name: "credential_document",
    description: "Access a connector-bound encrypted runtime document",
    schema: Zoi.object(%{request: Zoi.any()}),
    output_schema: Zoi.object(%{result: Zoi.any()})

  alias Zaq.Engine.Connect

  @impl Jido.Action
  def run(%{request: request}, %{credential_document_runtime: true}),
    do: {:ok, %{result: Connect.credential_document(request)}}

  def run(_, _), do: {:error, :unauthorized}
end
