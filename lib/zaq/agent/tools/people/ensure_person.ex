defmodule Zaq.Agent.Tools.People.EnsurePerson do
  @moduledoc """
  For each draft, looks up the recipient as a Person by email address.
  Creates a new Person if one doesn't exist yet.
  Passes drafts enriched with `:person_id` to the next action.
  """

  use Jido.Action,
    name: "ensure_person",
    schema: [
      drafts: [type: :any, required: true]
    ]

  require Logger

  alias Zaq.Accounts.{People, Person}
  alias Zaq.Repo

  @impl true
  def run(%{drafts: drafts}, _context) do
    enriched = Enum.map(drafts, &enrich/1)

    logs = [
      %{
        level: "info",
        message: "Ensured #{length(enriched)} person(s)",
        metadata: %{
          count: length(enriched),
          addresses: Enum.map(enriched, & &1.to_address)
        }
      }
    ]

    {:ok, %{drafts: enriched}, logs: logs}
  end

  defp enrich(draft) do
    name = non_empty(draft[:to_name]) || draft.to_address

    case Repo.get_by(Person, email: draft.to_address) do
      %Person{id: person_id, full_name: current_name} = person ->
        maybe_update_name(person, draft[:to_name], current_name, draft.to_address)
        Map.put(draft, :person_id, person_id)

      nil ->
        Logger.info("[EnsurePerson] Creating person for #{draft.to_address} (#{name})")
        create_and_enrich(draft, name)
    end
  end

  defp maybe_update_name(person, to_name, current_name, address) do
    if non_empty(to_name) && current_name == address do
      People.update_person(person, %{full_name: to_name})
      Logger.info("[EnsurePerson] Updated name for #{address} → #{to_name}")
    end
  end

  defp create_and_enrich(draft, name) do
    case People.create_person(%{email: draft.to_address, full_name: name}) do
      {:ok, person} -> Map.put(draft, :person_id, person.id)
      {:error, _} -> Map.put(draft, :person_id, nil)
    end
  end

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(v), do: v
end
