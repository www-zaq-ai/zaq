defmodule Zaq.TestSupport.Eventually do
  @moduledoc "Bounded test observation with explicit deadlines and timeout diagnostics."

  import ExUnit.Assertions

  def eventually(probe, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 2_000)
    observe(probe, System.monotonic_time(:millisecond) + timeout, opts)
  end

  defp observe(probe, deadline, opts) do
    value = probe.()
    matches? = Keyword.get(opts, :matches, & &1)

    cond do
      matches?.(value) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "Timed out waiting for #{Keyword.get(opts, :label, "condition")}; last observation: #{inspect(value)}"
        )

      true ->
        Process.sleep(Keyword.get(opts, :interval, 10))
        observe(probe, deadline, opts)
    end
  end
end
