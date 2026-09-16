defmodule Zaq.Engine.PeopleProfile do
  @moduledoc "Safe authenticated profile response; excludes identity history, metadata and authentication credentials."
  @enforce_keys [:person, :teams, :channels, :permissions]
  defstruct [:person, :teams, :channels, :permissions]

  @type t :: %__MODULE__{
          person: map(),
          teams: [map()],
          channels: [map()],
          permissions: MapSet.t(Zaq.Accounts.PeoplePermissionGrant.permission())
        }
end
