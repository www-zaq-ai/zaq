defmodule ZaqWeb.Components.LiveUpdateSettings do
  @moduledoc """
  Shared streamed-update fields embedded in the owning connector Edit form.

  The parent retains drafts and submits them with ordinary configuration fields.
  This component never persists changes or renders an independent form/save button.
  Status notifications remain outside these controls.
  """

  use Phoenix.Component

  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS
  alias Zaq.ConnectorConfig.LiveUpdates
  alias ZaqWeb.Components.DesignSystem.{Checkbox, Input}

  @triggers [
    {"stream_delta", "Answer content"},
    {"reasoning", "Reasoning"},
    {"tool_call", "Tool activity"}
  ]

  attr :id, :string, required: true
  attr :policy, :map, default: nil
  attr :errors, :map, default: %{}
  attr :load_error, :string, default: nil

  def fields(assigns) do
    assigns = assign(assigns, :triggers, @triggers)

    ~H"""
    <details
      id={@id}
      phx-mounted={JS.ignore_attributes("open")}
      class="mt-3 rounded-xl border p-4"
      style="background: var(--zaq-surface-color-elevated); border-color: var(--zaq-border-color-default)"
    >
      <summary class="zaq-text-body-sm cursor-pointer">Streamed message updates</summary>
      <p class="zaq-text-body-sm mt-3" style="color: var(--zaq-text-color-body-secondary)">
        Progress/status messages are unaffected and may still update the message.
        Selected events may trigger a streamed update when eligible; updates can include
        information from unselected events. All information is still recorded in traces.
      </p>
      <p :if={@load_error} role="alert" class="zaq-field-error">{@load_error}</p>
      <div :if={@policy} class="mt-4 space-y-4">
        <Checkbox.checkbox
          id={@id <> "-enabled"}
          name="live_updates[enabled]"
          label="Enable streamed message updates"
          checked={checked?(@policy["enabled"])}
        />
        <div>
          <Checkbox.checkbox
            id={@id <> "-throttle"}
            name="live_updates[throttle_enabled]"
            label="Limit streamed update frequency"
            checked={checked?(@policy["throttle_enabled"])}
            disabled={!checked?(@policy["enabled"])}
            aria-describedby={@id <> "-frequency-help"}
          />
          <p
            id={@id <> "-frequency-help"}
            class="zaq-text-body-sm mt-2"
            style="color: var(--zaq-text-color-body-secondary)"
          >
            When off, selected events can trigger updates without a minimum time interval.
            Answer and reasoning text still use internal batching.
          </p>
        </div>
        <Input.input
          id={@id <> "-interval"}
          name="live_updates[min_interval_ms]"
          label="Minimum streamed-update interval (ms)"
          type="number"
          value={@policy["min_interval_ms"]}
          min="1"
          step="1"
          disabled={!checked?(@policy["enabled"]) || !checked?(@policy["throttle_enabled"])}
          errors={List.wrap(@errors["min_interval_ms"])}
        />
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
          At most one streamed update per response during this interval. Eligibility is checked
          when events arrive; no update is scheduled. Progress/status messages do not count.
        </p>
        <fieldset class="space-y-2" disabled={!checked?(@policy["enabled"])}>
          <legend class="zaq-text-body-sm mb-2">Events that can trigger a streamed update</legend>
          <Checkbox.checkbox
            :for={{key, label} <- @triggers}
            id={@id <> "-" <> key}
            name={"live_updates[triggers][#{key}]"}
            label={label}
            checked={checked?(trigger_value(@policy, key))}
          />
        </fieldset>
        <p
          :for={{key, error} <- @errors}
          :if={key != "min_interval_ms"}
          role="alert"
          class="zaq-field-error"
        >
          {key}: {error}
        </p>
      </div>
    </details>
    """
  end

  @doc "Merges submitted fields with retained disabled preferences, stripping only known UI metadata."
  def merge_params(policy, params) when is_map(policy) and is_map(params) do
    params =
      Map.drop(
        params,
        ~w(_unused_enabled _unused_throttle_enabled _unused_min_interval_ms _unused_triggers)
      )

    triggers =
      case Map.get(params, "triggers", %{}) do
        triggers when is_map(triggers) ->
          submitted =
            Map.drop(triggers, ~w(_unused_stream_delta _unused_reasoning _unused_tool_call))

          current =
            if is_map(policy["triggers"]),
              do: policy["triggers"],
              else: LiveUpdates.defaults()["triggers"]

          Map.merge(current, submitted)

        invalid ->
          invalid
      end

    policy |> Map.merge(params) |> Map.put("triggers", triggers)
  end

  def merge_params(policy, _params), do: policy

  @doc "Returns field-addressed validation errors without writing settings."
  def errors(policy) do
    case LiveUpdates.normalize_form(policy) do
      {:ok, _} -> %{}
      {:error, errors} -> errors
    end
  end

  defp checked?(value), do: Form.normalize_value("checkbox", value)

  defp trigger_value(policy, key) do
    case policy["triggers"] do
      triggers when is_map(triggers) -> triggers[key]
      _ -> false
    end
  end
end
