defmodule ZaqWeb.Live.BO.Communication.ChannelDisablePolicy do
  @moduledoc "Adapter-specific confirmation copy for the shared connector toggle event."

  @doc "Requests confirmation only when disabling a WhatsApp profile."
  @spec before_disable(atom() | String.t(), map()) :: :proceed | {:confirm, String.t()}
  def before_disable(provider, %{enabled: true}) when provider in [:whatsapp, "whatsapp"] do
    {:confirm,
     "Disabling WhatsApp will log out this profile. You will need to link it again to reconnect."}
  end

  def before_disable(_, _), do: :proceed
end
