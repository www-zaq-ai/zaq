defmodule Zaq.RegistryLookupProbe do
  @moduledoc false
  @compile {:no_warn_undefined, :int}

  alias Zaq.Engine.Workflows

  def run do
    {:ok, {Registry, [abstract_code: {:raw_abstract_v1, forms}]}} =
      :beam_lib.chunks(:code.which(Registry), [:abstract_code])

    select = Enum.find(forms, &match?({:function, _, :select, 2, _}, &1))

    lines = select_lines(select)

    [break_line] = lines
    dir = Path.join(System.tmp_dir!(), "zaq-registry-probe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.cp!(:code.which(Registry), Path.join(dir, "Elixir.Registry.beam"))
    File.write!(Path.join(dir, "Elixir.Registry.erl"), String.duplicate("\n", break_line + 1))
    :code.unstick_mod(Registry)
    {:module, Registry} = :code.load_abs(String.to_charlist(Path.join(dir, "Elixir.Registry")))
    {:module, Registry} = :int.i(Registry)
    :ok = :int.break(Registry, break_line)
    {:ok, registry} = Registry.start_link(keys: :unique, name: Zaq.RegistryLookupProbe.Registry)
    Process.unlink(registry)
    [partition] = for {_, pid, _, _} <- Supervisor.which_children(registry), do: pid
    :ok = :sys.suspend(registry)
    parent = self()

    {reader, ref} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, Workflows.interrupt_in_flight_runs(registry: Zaq.RegistryLookupProbe.Registry)}
          rescue
            error -> {:raised, error.__struct__}
          end

        send(parent, {:result, self(), result})
      end)

    wait_for_break(reader, break_line, 500)
    partition_ref = Process.monitor(partition)
    Process.exit(partition, :kill)

    receive do
      {:DOWN, ^partition_ref, :process, ^partition, _} -> :ok
    after
      5_000 -> raise "partition did not stop"
    end

    true = Process.alive?(registry)
    :ok = :int.continue(reader)

    result =
      receive do
        {:result, ^reader, result} -> result
        {:DOWN, ^ref, :process, ^reader, reason} -> {:exit, reason}
      after
        5_000 -> raise "lookup did not finish"
      end

    File.rm_rf!(dir)
    result
  end

  defp select_lines(
         {:call, location, {:remote, _, {:atom, _, :ets}, {:atom, _, :select}}, [{:var, _, _}, _]}
       ),
       do: [line(location)]

  defp select_lines(term) when is_tuple(term), do: term |> Tuple.to_list() |> select_lines()
  defp select_lines(term) when is_list(term), do: Enum.flat_map(term, &select_lines/1)
  defp select_lines(_), do: []

  defp line({line, _column}), do: line
  defp line(line), do: line

  defp wait_for_break(_pid, _line, 0), do: raise("lookup did not reach breakpoint")

  defp wait_for_break(pid, line, attempts) do
    if Enum.any?(:int.snapshot(), &match?({^pid, _, :break, {Registry, ^line}}, &1)) do
      :ok
    else
      receive do
      after
        10 -> wait_for_break(pid, line, attempts - 1)
      end
    end
  end
end
