defmodule ZaqWeb.Live.BO.LabelEventsTest do
  use Zaq.DataCase, async: true
  import Zaq.AccountsFixtures
  alias Zaq.Ingestion.{Document, Labels}
  alias Zaq.Ingestion.Labels.DocumentAssignment
  alias ZaqWeb.Live.BO.LabelEvents

  setup do
    user = super_admin_fixture(%{must_change_password: false}) |> Repo.preload(:role)
    actor = %{user_id: user.id}
    {:ok, label} = Labels.save_definition(%{name: "Security", targets: ["document"]}, actor)
    {:ok, document} = Document.create(%{source: "chip-#{System.unique_integer([:positive])}"})
    resource = %{type: "document", id: document.id}

    {:ok, _} =
      Labels.edit_resource(
        resource,
        [%{label_id: label.id, operation: "add", expected_version: 0}],
        actor
      )

    %{user: user, label: label, resource: resource}
  end

  test "chip removal persists a manual exclusion and rejects a repeated removal", %{
    user: user,
    label: label,
    resource: resource
  } do
    assert {:ok, _} = LabelEvents.remove(user, resource, label.id)
    assignment = Repo.get_by!(DocumentAssignment, document_id: resource.id, label_id: label.id)
    assert assignment.selected == false
    assert assignment.origin == :manual
    assert {:error, :stale} = LabelEvents.remove(user, resource, label.id)
  end

  test "chip removal cannot bypass document permissions", %{label: label, resource: resource} do
    user = staff_fixture(%{must_change_password: false}) |> Repo.preload(:role)
    assert {:error, :forbidden} = LabelEvents.remove(user, resource, label.id)
    assert Repo.get_by!(DocumentAssignment, document_id: resource.id, label_id: label.id).selected
  end
end
