defimpl Runic.Identity.Projectable, for: Zaq.Contracts.Record do
  @moduledoc """
  Versioned identity for complete record payloads used in workflow facts.

  All fields, including provider data, contribute to identity. This projection
  does not alter the record carried by the fact or its public JSON contract.
  Nonportable nested values remain errors rather than being silently discarded.
  """

  def identity_document(record), do: {:zaq_record, 1, Map.from_struct(record)}
end

defimpl Runic.Identity.Projectable, for: Zaq.Storage.FileExplorer.Entry do
  @moduledoc """
  Versioned identity for disk entries retained in a record's provider data.

  Every entry field contributes to identity without changing the runtime struct.
  """

  def identity_document(entry), do: {:zaq_file_explorer_entry, 1, Map.from_struct(entry)}
end

defimpl Runic.Identity.Projectable, for: DateTime do
  @moduledoc """
  Versioned timestamp identity preserving calendar, zone, offset and precision.

  Workflow facts retain their original DateTime structs; only their identity
  document is projected into canonical data.
  """

  def identity_document(timestamp), do: {:datetime, 1, Map.from_struct(timestamp)}
end

defimpl Runic.Identity.Projectable, for: Date do
  @moduledoc "Versioned identity preserving every field of a workflow date value."

  def identity_document(date), do: {:date, 1, Map.from_struct(date)}
end

defimpl Runic.Identity.Projectable, for: NaiveDateTime do
  @moduledoc "Versioned identity preserving calendar and precision of naive workflow timestamps."

  def identity_document(timestamp), do: {:naive_datetime, 1, Map.from_struct(timestamp)}
end
