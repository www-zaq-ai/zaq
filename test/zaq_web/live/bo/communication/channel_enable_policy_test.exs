defmodule ZaqWeb.Live.BO.Communication.ChannelEnablePolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ZaqWeb.Live.BO.Communication.ChannelEnablePolicy

  test "enabled WhatsApp profiles open their connection flow" do
    for provider <- [:whatsapp, "whatsapp"] do
      assert :open_connection = ChannelEnablePolicy.after_enable(provider, %{enabled: true})
      assert :proceed = ChannelEnablePolicy.after_enable(provider, %{enabled: false})
    end
  end

  property "other adapters preserve the default presentation" do
    check all(
            provider <- string(:alphanumeric) |> filter(&(&1 != "whatsapp")),
            enabled <- boolean()
          ) do
      assert :proceed = ChannelEnablePolicy.after_enable(provider, %{enabled: enabled})
    end
  end
end
