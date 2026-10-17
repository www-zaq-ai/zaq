defmodule ZaqWeb.Live.BO.Communication.ChannelDisablePolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ZaqWeb.Live.BO.Communication.ChannelDisablePolicy

  test "WhatsApp disable explains logout and relinking" do
    assert {:confirm, message} = ChannelDisablePolicy.before_disable("whatsapp", %{enabled: true})
    assert message =~ "log out this profile"
    assert message =~ "link it again"
  end

  property "all other adapters preserve immediate toggling" do
    check all(
            provider <-
              member_of(
                ~w(mattermost telegram slack discord teams email:smtp email:imap web_widget)
              ),
            enabled <- boolean()
          ) do
      assert :proceed = ChannelDisablePolicy.before_disable(provider, %{enabled: enabled})
    end
  end

  test "enabling WhatsApp proceeds without confirmation" do
    assert :proceed = ChannelDisablePolicy.before_disable("whatsapp", %{enabled: false})
  end
end
