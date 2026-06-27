defmodule Zaq.People.IdentityPlug do
  @moduledoc """
  Compatibility plug that resolves a channel message author to a Person record.

  Channel ingress now resolves identity before dispatching agent events. This
  module remains as a small wrapper for callers that still need to enrich an
  `%Incoming{}` with a minimal `person` payload.

  Fast path: person already known and complete → record interaction, skip enrichment.
  Slow path: no match or incomplete → fetch profile via Channels.Router, then
  find_or_create.

  On any error, returns the message unchanged (`person` remains nil).
  """

  alias Zaq.Engine.Messages.Incoming
  alias Zaq.People.IdentityResolver

  @spec call(Incoming.t(), keyword()) :: Incoming.t()
  def call(%Incoming{} = incoming, opts) do
    case IdentityResolver.resolve(incoming, opts) do
      {:ok, person} -> %{incoming | person: IdentityResolver.person_payload(person)}
      {:error, _} -> incoming
    end
  end
end
