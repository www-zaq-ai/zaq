defmodule Zaq.LabelFixtures do
  @moduledoc "Shared label definition fixtures and real Ingestion event dispatch for tests."

  alias Zaq.Event
  alias Zaq.Ingestion.{Api, Labels}

  @doc "Creates a definition with overridable attributes through the label context."
  def label_definition(actor, attrs \\ %{}) do
    Labels.save_definition(
      Map.merge(
        %{
          name: "Security",
          description: "Access control",
          resources: ["document", "chunk"],
          value_type: "boolean",
          value_config: %{},
          assignment_type: "manual",
          threshold: 80
        },
        attrs
      ),
      actor
    )
  end

  @doc "Builds explicit option choices; tests can retain readable stable IDs independently of display edits."
  def option_config(values),
    do: %{"options" => Enum.map(values, &%{"id" => &1, "label" => &1})}

  @doc "Dispatches a confidential Ingestion event with the supplied actor."
  def label_event(action, request, actor, opts \\ []) do
    Event.new(request, :ingestion,
      actor: actor,
      opts: Keyword.merge(opts, action: action, confidential: true)
    )
    |> Api.handle_event(action, nil)
    |> Map.fetch!(:response)
  end
end
