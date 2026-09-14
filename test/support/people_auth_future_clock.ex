defmodule Zaq.TestSupport.PeopleAuthFutureClock do
  @moduledoc false
  def utc_now(:second), do: ~U[2090-01-01 00:00:00Z]
end
