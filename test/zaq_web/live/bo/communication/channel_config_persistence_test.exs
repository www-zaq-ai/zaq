defmodule ZaqWeb.Live.BO.Communication.ChannelConfigPersistenceTest do
  # A channel form renders only the settings subtrees it knows about, so these cover the
  # merge that keeps an unrendered subtree from being wiped on save.
  use Zaq.DataCase, async: false

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Repo
  alias ZaqWeb.Live.BO.Communication.ChannelConfigPersistence

  defp no_extra_validation, do: fn changeset, _provider -> changeset end

  defp existing(settings) do
    {:ok, config} =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        "name" => "Telegram",
        "provider" => "telegram",
        "kind" => "retrieval",
        "url" => "https://api.telegram.org",
        "token" => "secret",
        "settings" => settings
      })
      |> Repo.insert()

    config
  end

  defp persist(config, params) do
    ChannelConfigPersistence.persist(:edit, config, params, "telegram", no_extra_validation())
  end

  describe "persist/5 settings merge" do
    test "keeps subtrees the submitted form did not render" do
      config = existing(%{"jido_chat" => %{"bot_name" => "zaq_bot"}})

      assert {:ok, updated} =
               persist(config, %{"settings" => %{"attachments" => %{"volume" => "media"}}})

      assert updated.settings["jido_chat"]["bot_name"] == "zaq_bot"
      assert updated.settings["attachments"]["volume"] == "media"
    end

    test "overwrites the key the form did render" do
      config = existing(%{"attachments" => %{"volume" => "archives"}})

      assert {:ok, updated} =
               persist(config, %{"settings" => %{"attachments" => %{"volume" => "media"}}})

      assert updated.settings["attachments"]["volume"] == "media"
    end

    test "merges nested keys rather than replacing the whole subtree" do
      config = existing(%{"attachments" => %{"volume" => "archives", "retain" => "forever"}})

      assert {:ok, updated} =
               persist(config, %{"settings" => %{"attachments" => %{"volume" => "media"}}})

      assert updated.settings["attachments"]["volume"] == "media"
      assert updated.settings["attachments"]["retain"] == "forever"
    end

    test "leaves settings untouched when the form posts none" do
      config = existing(%{"jido_chat" => %{"bot_name" => "zaq_bot"}})

      assert {:ok, updated} = persist(config, %{"name" => "Renamed"})

      assert updated.name == "Renamed"
      assert updated.settings["jido_chat"]["bot_name"] == "zaq_bot"
    end

    test "a new config has nothing to merge into" do
      params = %{
        "name" => "Fresh",
        "provider" => "discord",
        "kind" => "retrieval",
        "url" => "https://discord.example",
        "token" => "t",
        "settings" => %{"attachments" => %{"volume" => "media"}}
      }

      assert {:ok, config} =
               ChannelConfigPersistence.persist(
                 :new,
                 nil,
                 params,
                 "discord",
                 no_extra_validation()
               )

      assert config.settings == %{"attachments" => %{"volume" => "media"}}
    end

    test "a non-map stored value is replaced rather than merged into" do
      config = existing(%{"attachments" => "nonsense"})

      assert {:ok, updated} =
               persist(config, %{"settings" => %{"attachments" => %{"volume" => "media"}}})

      assert updated.settings["attachments"]["volume"] == "media"
    end
  end
end
