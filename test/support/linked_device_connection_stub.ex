defmodule Zaq.TestSupport.LinkedDeviceConnectionStub do
  @moduledoc false
  def connect(config, opts) do
    parent = Keyword.fetch!(opts, :parent)

    case Agent.start(fn -> parent end, name: {:global, {__MODULE__, config.profile}}) do
      {:ok, pid} ->
        send(config.observer, {:connection, config.profile, pid, parent})
        {:ok, pid}

      {:error, _} ->
        {:error, :already_connected}
    end
  end

  def stop(pid, _opts) do
    if Process.alive?(pid), do: Agent.stop(pid)
    :ok
  end

  def deliver(
        pid,
        %Jido.Chat.EventEnvelope{
          event_type: :action,
          payload: %Jido.Chat.ActionEvent{metadata: %{category: :connection_lifecycle} = metadata}
        },
        _opts
      ),
      do: send(pid, {:lifecycle, metadata})

  def deliver(pid, payload, opts), do: send(pid, {:payload, payload, opts})
end
