defmodule Zaq.TestSupport.ApplicationEnv do
  @moduledoc "Restores application settings changed by serial tests, including absent keys."

  def put(app, key, value) do
    preserve(app, [key])
    Application.put_env(app, key, value)
  end

  def preserve(app, keys) do
    previous = Map.new(keys, &{&1, Application.fetch_env(app, &1)})

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(app, key, value)
        {key, :error} -> Application.delete_env(app, key)
      end)
    end)
  end
end
