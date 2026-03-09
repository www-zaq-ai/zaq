defmodule Zaq.Channels.Channel do
  @moduledoc """
  Behaviour that all channel adapters must implement.
  """

  @callback connect(config :: map()) :: {:ok, pid()} | {:error, term()}
  @callback disconnect(pid()) :: :ok
  @callback send_message(pid(), channel_id :: String.t(), message :: String.t()) ::
              :ok | {:error, term()}
  @callback handle_event(event :: map()) :: :ok
  @callback forward_to_engine(event :: map()) :: :ok | {:error, term()}
end
