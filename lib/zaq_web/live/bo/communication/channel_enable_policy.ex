defmodule ZaqWeb.Live.BO.Communication.ChannelEnablePolicy do
  @moduledoc "Adapter-specific presentation after enabling a saved connector."

  @doc "Opens the saved WhatsApp profile's connection flow after successful enablement."
  @spec after_enable(atom() | String.t(), map()) :: :proceed | :open_connection
  def after_enable(provider, %{enabled: true}) when provider in [:whatsapp, "whatsapp"],
    do: :open_connection

  def after_enable(_, _), do: :proceed
end
