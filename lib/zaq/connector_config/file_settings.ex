defmodule Zaq.ConnectorConfig.FileSettings do
  @moduledoc """
  Pure file configuration for communication channels, shared by BO forms,
  persistence and Channels.

  Stored limits are positive integer bytes or counts. Decimal MB form values
  represent exactly 1,000,000 bytes; fractional bytes are rejected. Transport
  facts come from capability metadata, while failure policy belongs to settings.
  Missing transport facts remain unresolved, including for file-capable adapters.
  """

  @limit_fields [
    :max_attachment_bytes,
    :max_attachment_bytes_per_message,
    :max_encoded_message_bytes,
    :max_upload_request_bytes,
    :max_attachments_per_message
  ]
  @mb_fields %{
    "max_attachment_mb" => "max_attachment_bytes",
    "max_attachment_total_mb" => "max_attachment_bytes_per_message",
    "max_upload_request_mb" => "max_upload_request_bytes",
    "max_encoded_message_mb" => "max_encoded_message_bytes"
  }
  @stored_fields Enum.map(@limit_fields, &to_string/1)
  @validation_rules [:greater_than, :greater_than_or_equal_to, :less_than, :less_than_or_equal_to]
  @metadata_fields [:type, :unit, :validation]
  @types Map.new(@limit_fields, &{&1, :integer}) |> Map.put(:send_on_file_failure, :boolean)
  @setting_keys Map.new(Map.keys(@types), &{to_string(&1), &1})

  alias Ecto.Changeset

  @doc "Reads only the selected connection's stored file configuration."
  @spec from_connection(map() | nil) :: map()
  def from_connection(%{settings: settings}) when is_map(settings),
    do: file_map(Map.get(settings, "file_delivery"))

  def from_connection(_), do: %{}

  @doc "Attaches shared validation errors to the owning schema field with file-local keys."
  @spec add_errors(Ecto.Changeset.t(), atom(), map(), keyword()) :: Ecto.Changeset.t()
  def add_errors(changeset, field, errors, opts \\ []) do
    Enum.reduce(errors, changeset, fn {key, message}, changeset ->
      Ecto.Changeset.add_error(changeset, field, message, Keyword.put(opts, :file_field, key))
    end)
  end

  @doc "Reads normalized capability facts retained by authoritative file validation."
  def validation_capabilities(%Changeset{errors: errors}) do
    Enum.find_value(errors, fn {_field, {_message, opts}} -> opts[:capabilities] end)
  end

  def validation_capabilities(errors) when is_map(errors), do: Map.get(errors, :capabilities)

  @doc "Projects file-local errors across persistence and presentation boundaries."
  @spec errors(Ecto.Changeset.t()) :: map()
  def errors(changeset) do
    Map.new(
      for {field, {message, options}} <- changeset.errors,
          key = options[:file_field] || if(field == :file_delivery, do: "file_delivery"),
          not is_nil(key),
          do: {key, message}
    )
  end

  @doc "Validates an embedded file-settings field using cached capability facts."
  @spec validate_changeset(Ecto.Changeset.t(), atom(), term()) :: Ecto.Changeset.t()
  def validate_changeset(changeset, field, snapshot) do
    case validate(Ecto.Changeset.get_field(changeset, field) || %{}, snapshot) do
      :ok -> changeset
      {:error, errors} -> add_errors(changeset, field, errors)
    end
  end

  @doc "Converts submitted decimal MB/count/policy fields to stored values and field errors."
  @spec normalize_form(term()) :: {:ok, map()} | {:error, map()}
  def normalize_form(form) when is_map(form) do
    {settings, errors} =
      Enum.reduce(form, {%{}, %{}}, fn {key, value}, {settings, errors} ->
        case normalize_value(key, value) do
          {:ok, stored_key, normalized} ->
            {Map.put(settings, stored_key, normalized), errors}

          :blank ->
            {settings, errors}

          {:error, message} ->
            {settings, Map.put(errors, key, message)}
        end
      end)

    if errors == %{}, do: {:ok, settings}, else: {:error, errors}
  end

  def normalize_form(_), do: {:error, %{"file_delivery" => "Must be a settings map"}}

  @doc "Merges a partial form; explicit blanks clear overrides and omitted fields are retained."
  @spec merge_form(map(), map()) :: {:ok, map()} | {:error, map()}
  def merge_form(existing, form) do
    with {:ok, normalized} <- normalize_form(form) do
      submitted_keys = Enum.map(Map.keys(form), &Map.get(@mb_fields, &1, &1))
      {:ok, existing |> Map.drop(submitted_keys) |> Map.merge(normalized)}
    end
  end

  @doc "Presents integer bytes as exact decimal MB, retaining invalid drafts and explicit false."
  @spec form_values(term()) :: map()
  def form_values(settings) when is_map(settings) do
    Enum.reduce(@mb_fields, Map.drop(settings, Map.values(@mb_fields)), fn {form_key, stored_key},
                                                                           acc ->
      case Map.get(settings, stored_key) do
        value when is_integer(value) and value > 0 -> Map.put_new(acc, form_key, megabytes(value))
        _ -> acc
      end
    end)
    |> Map.put_new("send_on_file_failure", true)
  end

  def form_values(_), do: %{"send_on_file_failure" => true}

  @doc "Returns declared metadata, independently of completed file sending support."
  @spec metadata(term()) :: map() | nil
  def metadata(%{kind: kind}) when kind in [:data_source, "data_source"], do: nil

  def metadata(snapshot) when is_map(snapshot) do
    case Map.get(snapshot, :file_delivery) do
      %{limits: limits} = metadata when is_map(limits) ->
        if valid_metadata?(metadata),
          do: normalize_metadata(metadata),
          else: nil

      _ ->
        nil
    end
  end

  def metadata(_), do: nil

  @doc "Uses the shared native/fallback support meanings; configuration metadata does not grant support."
  @spec supported?(term(), atom()) :: boolean()
  def supported?(%{kind: kind}, _) when kind in [:data_source, "data_source"], do: false

  def supported?(snapshot, capability) when is_map(snapshot) do
    resolved = Map.get(snapshot, :resolved, %{})
    is_map(resolved) and Map.get(resolved, capability) in [:native, :fallback, true]
  end

  def supported?(_, _), do: false

  @doc "Shows settings when configuration is declared or file delivery has an applicable policy."
  @spec visible?(term()) :: boolean()
  def visible?(snapshot) do
    case metadata(snapshot) do
      %{limits: limits} when map_size(limits) > 0 -> true
      _ -> supported?(snapshot, :file)
    end
  end

  @doc "Returns a limit definition; an absent declaration is fixed and unresolved."
  @spec limit(term(), atom()) :: map()
  def limit(snapshot, key) when key in @limit_fields do
    definition = get_in(metadata(snapshot) || %{}, [:limits, key]) || %{}

    %{
      value: Map.get(definition, :value, :unresolved),
      configurable: Map.get(definition, :configurable, false),
      required: Map.get(definition, :required, false)
    }
    |> Map.merge(Map.take(definition, @metadata_fields))
  end

  @doc "Validates stored configuration using the same declarations as forms and the resolver."
  @spec validate(term(), term()) :: :ok | {:error, map()}
  def validate(settings, snapshot) when is_map(settings) do
    changeset = validation_changeset(settings, snapshot)

    changeset =
      if settings != %{} and not visible?(snapshot),
        do:
          Changeset.add_error(
            changeset,
            :file_delivery,
            "File configuration capabilities are unavailable"
          ),
        else: changeset

    changeset = Enum.reduce(@limit_fields, changeset, &validate_limit(&1, settings, snapshot, &2))

    errors =
      Map.new(changeset.errors, fn {field, {message, options}} ->
        {options[:file_field] || to_string(field), message}
      end)

    if errors == %{}, do: :ok, else: {:error, errors}
  end

  def validate(_, _), do: {:error, %{"file_delivery" => "Must be a settings map"}}

  @doc "Resolves limits without conflating missing facts with explicitly inapplicable ceilings."
  @spec effective_limits(map(), map()) :: {:ok, map()} | {:error, map()}
  def effective_limits(settings, snapshot) do
    with :ok <- validate(settings, snapshot) do
      limits = Map.new(@limit_fields, &{&1, effective_limit(settings, snapshot, &1)})

      if positive?(limits.max_attachments_per_message),
        do: {:ok, limits},
        else: {:error, %{"max_attachments_per_message" => "Required for file delivery"}}
    end
  end

  defp validation_changeset(settings, snapshot) do
    effective =
      Map.new(@limit_fields, fn field ->
        value = effective_limit(settings, snapshot, field)
        {field, if(value in [:unresolved, :not_applicable], do: nil, else: value)}
      end)

    effective =
      Map.put(effective, :send_on_file_failure, Map.get(settings, "send_on_file_failure"))

    changeset = Changeset.cast({%{}, @types}, effective, Map.keys(@types), empty_values: [])

    Enum.reduce(settings, changeset, fn {key, value}, changeset ->
      with {:ok, field} <- Map.fetch(@setting_keys, key),
           {:ok, _} <- Ecto.Type.dump(Map.fetch!(@types, field), value),
           false <- is_nil(value) do
        changeset
      else
        _ ->
          Changeset.add_error(
            changeset,
            :file_delivery,
            "Must be a positive integer or a boolean policy",
            file_field: key
          )
      end
    end)
  end

  defp validate_limit(field, settings, snapshot, changeset) do
    key = to_string(field)
    definition = limit(snapshot, field)
    override = Map.get(settings, key)
    message = override_error(override, definition)
    changeset = if message, do: Changeset.add_error(changeset, field, message), else: changeset

    changeset =
      if supported?(snapshot, :file) and definition.required,
        do:
          Changeset.validate_required(changeset, [field], message: "Required for file delivery"),
        else: changeset

    changeset
    |> Changeset.validate_number(field,
      greater_than: 0,
      message: "Must be a positive integer or a boolean policy"
    )
    |> Changeset.validate_number(
      field,
      Map.to_list(Map.get(definition, :validation, %{})) ++
        [message: "Must satisfy the declared numeric limit"]
    )
  end

  defp override_error(nil, _), do: nil

  defp override_error(_, %{configurable: false}),
    do: "Fixed or unavailable transport limits cannot be overridden"

  defp override_error(_, %{value: :not_applicable}), do: "This limit is not applicable"

  defp override_error(value, %{value: ceiling})
       when is_integer(value) and value > 0 and is_integer(ceiling) and value > ceiling,
       do: "Must not exceed the transport limit"

  defp override_error(_, _), do: nil

  defp effective_limit(settings, snapshot, field),
    do: Map.get(settings, to_string(field), limit(snapshot, field).value)

  defp valid_metadata?(metadata) do
    Map.get(metadata, :transfer_mode, :unresolved) in [
      :upload_then_publish,
      :send_with_attachments,
      :unresolved
    ] and
      is_boolean(Map.get(metadata, :supports_attachment_edits, false)) and
      Enum.all?(metadata.limits, fn
        {key, definition} when key in @limit_fields and is_map(definition) ->
          value = Map.get(definition, :value, :unresolved)

          (positive?(value) or value in [:unresolved, :not_applicable]) and
            is_boolean(Map.get(definition, :configurable, false)) and
            is_boolean(Map.get(definition, :required, false)) and
            valid_limit_metadata?(key, definition)

        _ ->
          false
      end)
  end

  defp valid_limit_metadata?(key, definition) do
    unit = if key == :max_attachments_per_message, do: :count, else: :bytes
    rules = Map.get(definition, :validation, %{})

    Map.get(definition, :type, :integer) == :integer and
      Map.get(definition, :unit, unit) == unit and
      is_map(rules) and
      Enum.all?(rules, fn {rule, bound} ->
        rule in @validation_rules and is_integer(bound) and bound >= 0
      end)
  end

  defp normalize_metadata(metadata) do
    limits =
      Map.new(metadata.limits, fn {key, definition} ->
        {key,
         %{
           value: Map.get(definition, :value, :unresolved),
           configurable: Map.get(definition, :configurable, false),
           required: Map.get(definition, :required, false)
         }
         |> Map.merge(Map.take(definition, @metadata_fields))}
      end)

    %{
      limits: limits,
      transfer_mode: Map.get(metadata, :transfer_mode, :unresolved),
      supports_attachment_edits: Map.get(metadata, :supports_attachment_edits, false)
    }
  end

  defp normalize_value(key, value) when is_map_key(@mb_fields, key) do
    if blank?(value),
      do: :blank,
      else: normalize_megabytes(key, value)
  end

  defp normalize_value("send_on_file_failure", value) when value in [true, false],
    do: {:ok, "send_on_file_failure", value}

  defp normalize_value("send_on_file_failure", value) when value in ["true", "false"],
    do: {:ok, "send_on_file_failure", value == "true"}

  defp normalize_value(key, value) when key in @stored_fields do
    cond do
      blank?(value) -> :blank
      positive?(value) -> {:ok, key, value}
      key == "max_attachments_per_message" and is_binary(value) -> normalize_count(value)
      true -> {:error, "Enter a positive integer"}
    end
  end

  defp normalize_value(_, _), do: {:error, "Invalid file setting"}

  defp normalize_megabytes(key, value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/\A[0-9]+(?:\.[0-9]{1,6})?\z/, value) do
      [whole | fraction] = String.split(value, ".")
      fraction = fraction |> List.first("") |> String.pad_trailing(6, "0")
      bytes = String.to_integer(whole) * 1_000_000 + String.to_integer(fraction)

      if bytes > 0,
        do: {:ok, Map.fetch!(@mb_fields, key), bytes},
        else: {:error, "Enter a positive size in MB"}
    else
      {:error, "Enter a positive decimal MB value with at most six decimal places"}
    end
  end

  defp normalize_megabytes(_, _), do: {:error, "Enter an exact decimal MB value"}

  defp normalize_count(value) do
    case Integer.parse(String.trim(value)) do
      {count, ""} when count > 0 -> {:ok, "max_attachments_per_message", count}
      _ -> {:error, "Enter a positive integer"}
    end
  end

  defp megabytes(bytes) do
    whole = Integer.to_string(div(bytes, 1_000_000))
    fraction = rem(bytes, 1_000_000)

    if fraction == 0 do
      whole
    else
      whole <>
        "." <>
        (fraction
         |> Integer.to_string()
         |> String.pad_leading(6, "0")
         |> String.trim_trailing("0"))
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_), do: false
  defp positive?(value), do: is_integer(value) and value > 0
  defp file_map(value) when is_map(value), do: value
  defp file_map(_), do: %{}
end
