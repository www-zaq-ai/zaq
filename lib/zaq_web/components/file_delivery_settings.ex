defmodule ZaqWeb.Components.FileDeliverySettings do
  @moduledoc "Shared capability-driven file controls for connection forms."
  use ZaqWeb, :html

  alias Zaq.ConnectorConfig.FileSettings
  alias ZaqWeb.Components.DesignSystem.{Button, FeedbackBanner, FieldHint, Input, Switch}

  @fields [
    %{
      key: :max_attachment_bytes,
      input: "max_attachment_mb",
      label: "Maximum file size (MB)",
      bytes?: true
    },
    %{
      key: :max_encoded_message_bytes,
      input: "max_encoded_message_mb",
      label: "Maximum encoded message size (MB)",
      bytes?: true
    },
    %{
      key: :max_attachments_per_message,
      input: "max_attachments_per_message",
      label: "Maximum attachments per message",
      bytes?: false
    }
  ]

  @additional_fields [
    %{
      key: :max_attachment_bytes_per_message,
      input: "max_attachment_total_mb",
      label: "Maximum total attachment size (MB)",
      bytes?: true
    },
    %{
      key: :max_upload_request_bytes,
      input: "max_upload_request_mb",
      label: "Maximum upload request size (MB)",
      bytes?: true
    }
  ]

  @usage_markers Enum.map(@fields ++ @additional_fields, &("_unused_" <> &1.input)) ++
                   ["_unused_send_on_file_failure"]

  @doc "Removes known LiveView usage markers at the file-controls path, preserving omitted fields."
  def form_params(params, []), do: clean_file_params(params)

  def form_params(params, [key | path]) when is_map(params) do
    case Map.fetch(params, key) do
      {:ok, value} -> Map.put(params, key, form_params(value, path))
      :error -> params
    end
  end

  def form_params(params, _path), do: params

  defp clean_file_params(params) when is_map(params), do: Map.drop(params, @usage_markers)
  defp clean_file_params(params), do: params

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :snapshot, :any, default: nil
  attr :settings, :any, default: %{}
  attr :errors, :map, default: %{}
  attr :heading, :boolean, default: true
  attr :unavailable, :boolean, default: false

  def section(assigns) do
    assigns =
      assigns
      |> assign(:visible?, FileSettings.visible?(assigns.snapshot))
      |> assign(:fields, fields(assigns.snapshot))
      |> assign(:values, FileSettings.form_values(assigns.settings))
      |> assign(
        :required_errors,
        case FileSettings.validate(%{}, assigns.snapshot) do
          :ok -> %{}
          {:error, errors} -> errors
        end
      )

    ~H"""
    <section :if={@visible? || @unavailable} id={@id} class="zaq-layout-stack">
      <h3 :if={@heading} class="zaq-text-h3">File delivery</h3>
      <%= if @unavailable do %>
        <FeedbackBanner.feedback_banner
          id={@id <> "-unavailable"}
          kind={:error}
          message="Capabilities unavailable. Retry to inspect this connection's file settings."
          auto_dismiss={false}
          dismissible={false}
        />
        <Button.button variant={:secondary} phx-click="open_capabilities">Retry capabilities</Button.button>
      <% else %>
        <p :if={not FileSettings.supported?(@snapshot, :file)} class="zaq-text-body-sm">
          Attachment sending is unavailable for this connection.
        </p>
        <div :for={field <- @fields} class="zaq-layout-stack-tight">
          <% definition = FileSettings.limit(@snapshot, field.key) %>
          <% error = Map.get(@errors, field.input) || Map.get(@errors, to_string(field.key)) %>
          <% required? = @required_errors[to_string(field.key)] == "Required for file delivery" %>
          <% bounds = bounds(definition, field) %>
          <%= if definition.configurable && definition.value != :not_applicable do %>
            <Input.input
              id={@id <> "-" <> field.input}
              name={@name <> "[" <> field.input <> "]"}
              type="number"
              label={field.label}
              value={Map.get(@values, field.input)}
              min={bounds.min}
              step={if field.bytes?, do: "0.000001", else: "1"}
              max={bounds.max}
              hint={hint(field, required?)}
              errors={List.wrap(error)}
              error_id={@id <> "-" <> field.input <> "-error"}
              aria-required={to_string(required?)}
              aria-invalid={to_string(not is_nil(error))}
              aria-describedby={if error, do: @id <> "-" <> field.input <> "-error"}
            />
          <% else %>
            <p class="zaq-text-body-sm">
              {field.label}: <strong>{limit_text(definition.value, field)}</strong>
            </p>
            <p :if={is_integer(definition.value)} class="zaq-text-caption">Fixed transport limit</p>
          <% end %>
          <FieldHint.field_messages
            :if={!definition.configurable || definition.value == :not_applicable}
            errors={List.wrap(error)}
            error_id={@id <> "-" <> field.input <> "-error"}
          />
        </div>
        <Switch.switch
          id={@id <> "-send_on_file_failure"}
          name={@name <> "[send_on_file_failure]"}
          label="Send message if files fail"
          description="Continue with the message when its files cannot be delivered."
          layout={:setting_row}
          checked={@values["send_on_file_failure"] in [true, "true"]}
        />
        <FieldHint.field_messages errors={List.wrap(@errors["send_on_file_failure"])} />
        <FieldHint.field_messages
          errors={List.wrap(@errors["file_delivery"])}
          error_id={@id <> "-error"}
        />
      <% end %>
    </section>
    """
  end

  @doc "Extracts file-local errors without duplicating changeset error conventions in forms."
  defdelegate errors(changeset), to: FileSettings

  defp fields(snapshot) do
    limits = (FileSettings.metadata(snapshot) || %{limits: %{}}).limits
    @fields ++ Enum.filter(@additional_fields, &Map.has_key?(limits, &1.key))
  end

  defp hint(field, required?) do
    requirement =
      if required?, do: "Required for file delivery. ", else: "Optional override. "

    units =
      if field.bytes?, do: "1 MB = 1,000,000 bytes. ", else: "Enter a positive whole number. "

    scope =
      if field.key == :max_encoded_message_bytes,
        do: "Includes the body, headers and encoded attachments. ",
        else: ""

    fallback =
      if required?,
        do: "Enter a value because the transport has no fixed limit for this setting.",
        else: "Leave blank to use the transport limit; an unknown limit remains unresolved."

    requirement <> scope <> units <> fallback
  end

  defp bounds(definition, field) do
    rules = Map.get(definition, :validation, %{})

    minimum =
      Enum.max([
        1,
        Map.get(rules, :greater_than, 0) + 1,
        Map.get(rules, :greater_than_or_equal_to, 1)
      ])

    upper = [
      definition.value,
      Map.get(rules, :less_than_or_equal_to),
      if(is_integer(rules[:less_than]), do: rules.less_than - 1)
    ]

    maximum = upper |> Enum.filter(&is_integer/1) |> Enum.min(fn -> nil end)
    %{min: ceiling(minimum, field), max: if(maximum == 0, do: "0", else: ceiling(maximum, field))}
  end

  defp ceiling(value, field) when is_integer(value) and value > 0 do
    if field.bytes?,
      do: FileSettings.form_values(%{to_string(field.key) => value})[field.input],
      else: to_string(value)
  end

  defp ceiling(_, _), do: nil

  defp limit_text(:not_applicable, _), do: "Not applicable"
  defp limit_text(:unsupported, _), do: "Unsupported"

  defp limit_text(value, field) when is_integer(value) and value > 0 do
    ceiling(value, field) <> if(field.bytes?, do: " MB", else: "")
  end

  defp limit_text(_, _), do: "Unresolved"
end
