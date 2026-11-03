defmodule Zaq.Ingestion.Labels.AssignmentValue do
  @moduledoc "Shared normalization and validation for optional per-resource label values."
  import Ecto.Changeset

  def valid?(nil), do: true

  def valid?(value) when is_binary(value),
    do: String.valid?(value) and String.length(value) <= 200

  def valid?(_), do: false

  def normalize(nil), do: nil

  def normalize(value) do
    case value |> String.trim() |> String.normalize(:nfc) do
      "" -> nil
      normalized -> normalized
    end
  end

  def put(changeset, false, _value), do: put_change(changeset, :value, nil)
  def put(changeset, true, :unchanged), do: changeset

  def put(changeset, true, value) do
    if valid?(value),
      do: put_change(changeset, :value, normalize(value)),
      else: add_error(changeset, :value, "must be text of at most 200 characters")
  end
end
