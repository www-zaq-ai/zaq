defmodule Zaq.ChannelCapabilityFixtures do
  @moduledoc false

  alias Zaq.Channels.Bridge

  def observe_capability_lookups do
    Code.ensure_loaded!(Bridge)
    mfa = {Bridge, :capability_snapshot, 2}
    :erlang.trace_pattern(mfa, true, [:call_count])
    ExUnit.Callbacks.on_exit(fn -> :erlang.trace_pattern(mfa, false, [:call_count]) end)
  end

  def capability_lookup_count do
    {:call_count, count} = :erlang.trace_info({Bridge, :capability_snapshot, 2}, :call_count)
    count
  end

  # Provider lookup has no per-LiveView config seam. Use only in synchronous tests
  # and restore registration; all requests still execute the real service boundaries.
  def remove_capability_bridge(provider_key) do
    channels = Application.get_env(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.update!(channels, provider_key, &Map.delete(&1, :bridge))
    )

    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:zaq, :channels, channels) end)
    channels
  end
end
