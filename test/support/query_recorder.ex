defmodule Zaq.QueryRecorder do
  @moduledoc "Records synchronous queries from the calling test process only."

  def capture(fun) do
    ref = make_ref()
    :ok = :telemetry.attach(ref, [:zaq, :repo, :query], &__MODULE__.record/4, {self(), ref})

    try do
      result = fun.()
      {result, collect(ref, [])}
    after
      :telemetry.detach(ref)
    end
  end

  def record(_event, _measurements, metadata, {owner, ref}) do
    if self() == owner,
      do: send(owner, {ref, Map.put(metadata, :in_transaction, Zaq.Repo.in_transaction?())})
  end

  defp collect(ref, queries) do
    receive do
      {^ref, metadata} -> collect(ref, [metadata | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end
end
