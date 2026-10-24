defmodule ZaqWeb.Live.BO.Communication.ChannelEnablePolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.ConnectorConfig.Settings

  test "WhatsApp enable availability requires a super-admin without restricting disable" do
    for provider <- [:whatsapp, "whatsapp"] do
      for user <- [nil, %{}, %{role: %{name: "admin"}}, %{role: %{name: "staff"}}] do
        assert Settings.enable_disabled_reason(%{provider: provider, enabled: false}, user) ==
                 "Only super admins can enable a WhatsApp account."

        assert is_nil(Settings.enable_disabled_reason(%{provider: provider, enabled: true}, user))
      end

      assert is_nil(
               Settings.enable_disabled_reason(
                 %{provider: provider, enabled: false},
                 %{role: %{name: "super_admin"}}
               )
             )
    end
  end

  property "other adapters retain their toggle availability regardless of role" do
    check all(
            provider <- string(:alphanumeric) |> filter(&(&1 != "whatsapp")),
            enabled <- boolean(),
            user <-
              member_of([nil, %{}, %{role: %{name: "staff"}}, %{role: %{name: "super_admin"}}])
          ) do
      assert is_nil(
               Settings.enable_disabled_reason(%{provider: provider, enabled: enabled}, user)
             )
    end
  end
end
