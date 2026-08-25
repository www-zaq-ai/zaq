defmodule Zaq.Storage.StorageEntry do
  @moduledoc """
  Resource identity for source-scoped permissions on mounted storage entries.

  The struct exists so `Zaq.Permissions` derives the resource type
  `"storage_entry"` while the id remains the stable storage source locator.
  """

  @enforce_keys [:id]
  defstruct [:id]
end
