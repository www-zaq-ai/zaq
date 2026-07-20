defmodule Zaq.RuntimeDepsTest do
  use ExUnit.Case, async: false

  alias Zaq.Channels.ChannelConfig
  alias Zaq.RuntimeDeps

  defmodule ChannelConfigStub do
  end

  describe "channel_config/0" do
    test "returns the production channel config module by default" do
      original = Application.get_env(:zaq, :channels_live_channel_config_module)
      Application.delete_env(:zaq, :channels_live_channel_config_module)

      on_exit(fn ->
        if original do
          Application.put_env(:zaq, :channels_live_channel_config_module, original)
        else
          Application.delete_env(:zaq, :channels_live_channel_config_module)
        end
      end)

      assert RuntimeDeps.channel_config() == ChannelConfig
    end

    test "returns the configured channel config module when overridden" do
      original = Application.get_env(:zaq, :channels_live_channel_config_module)
      Application.put_env(:zaq, :channels_live_channel_config_module, ChannelConfigStub)

      on_exit(fn ->
        if original do
          Application.put_env(:zaq, :channels_live_channel_config_module, original)
        else
          Application.delete_env(:zaq, :channels_live_channel_config_module)
        end
      end)

      assert RuntimeDeps.channel_config() == ChannelConfigStub
    end
  end
end
