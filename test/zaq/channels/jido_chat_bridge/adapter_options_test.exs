defmodule Zaq.Channels.JidoChatBridge.AdapterOptionsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.JidoChatBridge.AdapterOptions
  alias Zaq.Engine.ChannelConfig

  @default_providers [:mattermost, :discord, :telegram, "mattermost", "discord", "telegram"]

  describe "build/2 default credential shape" do
    test "default providers always receive exactly url then token" do
      check all(
              provider <- member_of(@default_providers),
              url <- one_of([constant(nil), string(:printable, max_length: 40)]),
              token <- one_of([constant(nil), string(:alphanumeric, max_length: 40)])
            ) do
        assert AdapterOptions.build(provider, %{url: url, token: token}) ==
                 [url: url, token: token]
      end
    end

    test "reads a channel config struct" do
      config = %ChannelConfig{
        provider: "mattermost",
        url: "https://mm.example.test",
        token: "abc"
      }

      assert AdapterOptions.build(config.provider, config) ==
               [url: "https://mm.example.test", token: "abc"]
    end

    test "reads string-keyed connection maps" do
      assert AdapterOptions.build("telegram", %{
               "url" => "https://tg.example.test",
               "token" => "s"
             }) ==
               [url: "https://tg.example.test", token: "s"]
    end

    test "keeps missing credentials as nil values" do
      assert AdapterOptions.build(:discord, %{}) == [url: nil, token: nil]
    end
  end
end
