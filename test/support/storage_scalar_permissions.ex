defmodule Zaq.Test.StorageScalarPermissions do
  @moduledoc false

  alias Zaq.Permissions

  defdelegate list_effective(resource, opts), to: Permissions
  defdelegate everyone_team_id(), to: Permissions
  defdelegate access(person, right), to: Permissions
  defdelegate grants_allow?(grants, access), to: Permissions
end
