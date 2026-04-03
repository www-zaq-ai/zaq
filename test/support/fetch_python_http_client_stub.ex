defmodule Zaq.FetchPythonHTTPClientStub do
  @moduledoc false

  @responder_key {__MODULE__, :responder}

  def put_responder(fun) when is_function(fun, 2) do
    Process.put(@responder_key, fun)
    :ok
  end

  def clear_responder do
    Process.delete(@responder_key)
    :ok
  end

  def get(url, opts \\ []) do
    case Process.get(@responder_key) do
      nil ->
        raise "No HTTP responder configured for #{inspect(__MODULE__)}"

      fun ->
        fun.(url, opts)
    end
  end
end
