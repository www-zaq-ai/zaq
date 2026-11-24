defmodule Zaq.Agent.KnowledgeAccess do
  @moduledoc """
  Translates trusted tool context into Ingestion access options for knowledge reads.

  Ingestion owns permission evaluation. Source scope and explicit permission bypass
  apply independently of the caller's identity.
  """

  alias Zaq.Identity.{ActorNormalizer, ExecutionActor}

  @doc "Builds access options without consulting tool parameters or flat context identities."
  @spec options(map()) :: keyword()
  def options(context) do
    actor =
      case ExecutionActor.validate(context[:actor]) do
        {:ok, actor} -> actor
        {:error, _reason} -> nil
      end

    [
      person_id: ActorNormalizer.person_id(actor),
      team_ids: ActorNormalizer.team_ids(actor),
      skip_permissions: context[:skip_permissions] == true,
      source_filter: context[:source_filter]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
