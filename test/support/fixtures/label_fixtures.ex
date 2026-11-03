defmodule Zaq.LabelFixtures do
  @moduledoc "Shared label definition fixtures and real Ingestion event dispatch for tests."

  alias Zaq.Event
  alias Zaq.Ingestion.{Api, Labels}

  @doc "Creates a definition with overridable attributes through the label context."
  def label_definition(actor, attrs \\ %{}) do
    Labels.save_definition(
      Map.merge(
        %{name: "Security", description: "Access control", targets: ["document", "chunk"]},
        attrs
      ),
      actor
    )
  end

  @doc "Dispatches a confidential Ingestion event with the supplied actor."
  def label_event(action, request, actor) do
    Event.new(request, :ingestion, actor: actor, opts: [action: action, confidential: true])
    |> Api.handle_event(action, nil)
    |> Map.fetch!(:response)
  end
end
