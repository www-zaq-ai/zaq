defmodule Zaq.Config do
  @moduledoc false

  def get(app, key, default, opts \\ []) do
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
end
