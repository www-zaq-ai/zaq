defmodule ZaqWeb.Components.DesignSystem.LabelValue do
  @moduledoc """
  Shared typed label controls and display text for resource and bulk editors.

  Controls serialize native values to HTML. `parse_input/2` only reverses that
  serialization; Ingestion owns membership, range, grid and assignment validation.
  """
  use Phoenix.Component
  alias ZaqWeb.Components.DesignSystem.Input
  import ZaqWeb.Components.SearchableSelect, only: [searchable_select: 1]

  attr :definition, :map, required: true
  attr :value, :any, default: nil
  attr :id, :string, required: true
  attr :name, :string, default: "value"
  attr :label, :string, default: nil
  attr :editable, :boolean, default: true
  attr :target, :any, default: nil

  @doc "Renders one definition-owned value control, without a surrounding form."
  def value_input(assigns) do
    assigns =
      assigns
      |> assign(:config, Map.get(assigns.definition, :value_config, %{}))
      |> assign(:wire_value, wire_value(assigns.value))

    ~H"""
    <%= if @definition.value_type == "scale" do %>
      <Input.input
        id={@id}
        name={@name}
        label={@label}
        type="number"
        value={@wire_value}
        min={@config["min"]}
        max={@config["max"]}
        step={@config["increment"]}
        disabled={!@editable}
      />
    <% else %>
      <.searchable_select
        id={@id}
        name={@name}
        value={@wire_value}
        options={input_options(@definition)}
        label={@label}
        label_position="block"
        empty_label="Choose a value"
        placeholder="Search defined values"
        searchable={@definition.value_type == "options"}
        disabled={!@editable}
        target={@target}
        compact
      />
    <% end %>
    """
  end

  @doc "Decodes HTML scalar values; definition-specific validation stays in Ingestion."
  def parse_input(_definition, ""), do: {:ok, nil}
  def parse_input(_definition, nil), do: {:ok, nil}
  def parse_input(%{value_type: "boolean"}, "true"), do: {:ok, true}
  def parse_input(%{value_type: "boolean"}, "false"), do: {:ok, false}
  def parse_input(%{value_type: "boolean"}, value) when is_boolean(value), do: {:ok, value}

  def parse_input(%{value_type: "scale"}, value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> parse_float(value)
    end
  end

  def parse_input(%{value_type: "scale"}, value) when is_number(value), do: {:ok, value}
  def parse_input(%{value_type: "options"}, value) when is_binary(value), do: {:ok, value}
  def parse_input(_definition, _value), do: :error

  @doc "Formats a native value, resolving stable option IDs to their display labels."
  def format_value(_definition, nil), do: "No value"
  def format_value(_definition, true), do: "True"
  def format_value(_definition, false), do: "False"

  def format_value(%{value_type: "options", value_config: %{"options" => options}}, value) do
    case Enum.find(options, &(&1["id"] == value)) do
      nil -> to_string(value)
      option -> option["label"]
    end
  end

  def format_value(_definition, value), do: to_string(value)

  @doc "Formats a chip label while keeping pending and excluded distinct from values."
  def display_label(label) do
    case Map.get(label, :state) do
      :pending -> "#{label.name}: Pending automatic"
      :excluded -> "#{label.name}: Excluded"
      _ -> label_with_value(label)
    end
  end

  @doc "Returns saved assignment state text for editor rows."
  def status_text(label) do
    case Map.get(label, :state) do
      :pending -> "Pending automatic"
      :excluded -> "Excluded"
      _ -> ""
    end
  end

  defp label_with_value(label) do
    case Map.get(label, :value) do
      value when value in [nil, ""] -> label.name
      value -> "#{label.name}: #{format_value(label, value)}"
    end
  end

  defp wire_value(nil), do: ""
  defp wire_value(value), do: to_string(value)

  defp input_options(%{value_type: "boolean"}), do: [{"True", "true"}, {"False", "false"}]

  defp input_options(%{value_type: "options", value_config: %{"options" => options}}),
    do: Enum.map(options, &{&1["label"], &1["id"]})

  defp parse_float(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end
end
