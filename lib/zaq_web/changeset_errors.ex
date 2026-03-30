defmodule ZaqWeb.ChangesetErrors do
  @moduledoc """
  Shared helpers to format Ecto changeset errors for UI rendering.
  """

  @doc """
  Formats a changeset into either a single string or a list of messages.

  Options:
  - `:join` - when `true` returns a single string, otherwise a list (default: `true`)
  - `:separator` - separator used when joining (default: `", "`)
  - `:include_field` - include field names in messages (default: `true`)
  - `:humanize_fields` - convert field names with `Phoenix.Naming.humanize/1` (default: `false`)
  - `:field_separator` - separator between field and message (default: `": "`)
  """
  def format(%Ecto.Changeset{} = changeset, opts \\ []) do
    messages =
      changeset
      |> traverse()
      |> flatten(opts)

    if Keyword.get(opts, :join, true) do
      Enum.join(messages, Keyword.get(opts, :separator, ", "))
    else
      messages
    end
  end

  @doc """
  Returns `%{field => [messages]}` with interpolation applied.
  """
  def traverse(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp flatten(errors_map, opts) do
    include_field = Keyword.get(opts, :include_field, true)
    humanize_fields = Keyword.get(opts, :humanize_fields, false)
    field_separator = Keyword.get(opts, :field_separator, ": ")

    Enum.flat_map(errors_map, fn {field, errors} ->
      field_label = format_field(field, humanize_fields)

      Enum.map(errors, fn error ->
        build_message(error, field_label, field_separator, include_field)
      end)
    end)
  end

  defp format_field(field, true), do: Phoenix.Naming.humanize(field)
  defp format_field(field, false), do: to_string(field)

  defp build_message(error, field_label, field_separator, true),
    do: field_label <> field_separator <> error

  defp build_message(error, _field_label, _field_separator, false), do: error
end
