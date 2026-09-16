defmodule Zaq.TestSupport.PeopleAuthClock do
  @moduledoc false
  def put(now), do: Process.put(__MODULE__, now)
  def utc_now(:second), do: Process.get(__MODULE__) || raise("Test clock must be set")
end
