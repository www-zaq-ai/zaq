defmodule Zaq.Config do
  @moduledoc """
  Configuration reads with a process-scoped override seam.

  Resolution order, first hit wins:

    1. A process override set by `put_process/3`, looked up on the calling
       process and then along its `$callers` chain (nearest caller first).
    2. A config module injected as `opts[:config]`.
    3. `Application.get_env/3`.

  The process override exists so concurrent tests can inject collaborators
  without mutating global application env, which is what forces those tests to
  run serially.
  """

  @override_prefix :"$zaq_config"
  @miss :"$zaq_config_miss"

  def get(app, key, default, opts \\ []) do
    case fetch_override(app, key) do
      {:ok, value} -> value
      :error -> get_without_override(app, key, default, opts)
    end
  end

  @doc """
  Sets a config override visible to this process and to any process that lists
  it in `$callers`. Scoped to the process, so it never leaks across concurrent
  tests.
  """
  def put_process(app, key, value) do
    Process.put(override_key(app, key), value)
    :ok
  end

  @doc "Removes an override set by `put_process/3`, restoring the underlying value."
  def delete_process(app, key) do
    Process.delete(override_key(app, key))
    :ok
  end

  defp get_without_override(app, key, default, opts) do
    case Keyword.get(opts, :config, __MODULE__) do
      nil -> Application.get_env(app, key, default)
      __MODULE__ -> Application.get_env(app, key, default)
      module -> delegate_get(module, app, key, default, opts)
    end
  end

  defp delegate_get(module, app, key, default, opts) when is_atom(module) do
    cond do
      function_exported?(module, :get, 4) -> module.get(app, key, default, opts)
      function_exported?(module, :get, 3) -> module.get(app, key, default)
      true -> Application.get_env(app, key, default)
    end
  end

  defp delegate_get(_module, app, key, default, _opts), do: Application.get_env(app, key, default)

  defp override_key(app, key), do: {@override_prefix, app, key}

  defp fetch_override(app, key) do
    override_key = override_key(app, key)

    [self() | Process.get(:"$callers", [])]
    |> Enum.find_value(:error, fn pid ->
      case lookup(pid, override_key) do
        {:ok, _value} = hit -> hit
        :error -> nil
      end
    end)
  end

  defp lookup(pid, override_key) when pid == self() do
    unwrap(Process.get(override_key, @miss))
  end

  defp lookup(pid, override_key) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case List.keyfind(dictionary, override_key, 0, @miss) do
          {^override_key, value} -> {:ok, value}
          _miss -> :error
        end

      _dead ->
        :error
    end
  end

  defp unwrap(@miss), do: :error
  defp unwrap(value), do: {:ok, value}
end
