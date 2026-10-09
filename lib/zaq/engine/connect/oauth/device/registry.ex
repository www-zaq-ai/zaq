defmodule Zaq.Engine.Connect.OAuth.Device.Registry do
  @moduledoc "Static device-flow capabilities keyed by existing OAuth profile IDs."
  alias Zaq.Engine.Connect.OAuth.Device.Codex

  def fetch("openai_chatgpt_codex"), do: {:ok, Codex}
  def fetch(_), do: {:error, :unsupported_device_flow}
end
