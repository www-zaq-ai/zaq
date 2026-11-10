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

  describe "build/2 Teams credential shape" do
    test "Teams always receives exactly app_id, app_password and app_tenant_id" do
      check all(
              provider <- member_of([:teams, "teams"]),
              app_id <- string(:alphanumeric, min_length: 1, max_length: 40),
              tenant_id <- string(:alphanumeric, min_length: 1, max_length: 40),
              token <- string(:alphanumeric, min_length: 1, max_length: 40)
            ) do
        connection = %{
          url: "https://unused.example.test",
          token: token,
          settings: %{"jido_chat" => %{"app_id" => app_id, "tenant_id" => tenant_id}}
        }

        assert AdapterOptions.build(provider, connection) ==
                 [app_id: app_id, app_password: token, app_tenant_id: tenant_id]
      end
    end

    test "reads a channel config struct" do
      config = %ChannelConfig{
        provider: "teams",
        token: "client-secret",
        settings: %{"jido_chat" => %{"app_id" => "app-1", "tenant_id" => "tenant-1"}}
      }

      assert AdapterOptions.build(config.provider, config) ==
               [app_id: "app-1", app_password: "client-secret", app_tenant_id: "tenant-1"]
    end

    test "keeps missing credentials as nil values" do
      assert AdapterOptions.build(:teams, %{}) ==
               [app_id: nil, app_password: nil, app_tenant_id: nil]

      assert AdapterOptions.build("teams", %{token: "client-secret", settings: nil}) ==
               [app_id: nil, app_password: "client-secret", app_tenant_id: nil]
    end
  end
end
