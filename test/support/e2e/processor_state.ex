defmodule Zaq.E2E.ProcessorState do
  @moduledoc false

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> 0 end, name: __MODULE__)
  end

  @doc "Set the number of consecutive failures the fake processor will return."
  def set_fail(count) when is_integer(count) and count >= 0 do
    Agent.update(__MODULE__, fn _ -> count end)
  end

  def reset do
    Agent.update(__MODULE__, fn _ -> 0 end)
  end

  @doc "Returns :fail and decrements counter, or :ok when counter is zero."
  def check_and_consume do
    Agent.get_and_update(__MODULE__, fn
      0 -> {:ok, 0}
      n -> {:fail, n - 1}
    end)
  end
end
