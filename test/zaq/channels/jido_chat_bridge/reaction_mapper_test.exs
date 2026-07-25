defmodule Zaq.Channels.JidoChatBridge.ReactionMapperTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.JidoChatBridge.ReactionMapper

  describe "to_rating/2 unicode emoji" do
    test "maps positive unicode emoji to the top rating for any provider" do
      for provider <- [:mattermost, :slack, :discord, :telegram, :unknown],
          emoji <- ["\u{1F44D}", "\u{1F525}"] do
        assert {:ok, 5} = ReactionMapper.to_rating(provider, emoji)
      end
    end

    test "maps the negative unicode emoji to the bottom rating for any provider" do
      for provider <- [:mattermost, :slack, :discord, :telegram, :unknown] do
        assert {:ok, 1} = ReactionMapper.to_rating(provider, "\u{1F44E}")
      end
    end
  end

  describe "to_rating/2 provider short names" do
    test "maps positive short names for providers that send them" do
      for provider <- [:mattermost, :slack],
          emoji <- ["thumbsup", "thumbs_up", "+1"] do
        assert {:ok, 5} = ReactionMapper.to_rating(provider, emoji)
      end

      assert {:ok, 5} = ReactionMapper.to_rating(:discord, "thumbsup")
      assert {:ok, 5} = ReactionMapper.to_rating(:discord, "+1")
    end

    test "maps negative short names for providers that send them" do
      for provider <- [:mattermost, :slack],
          emoji <- ["thumbsdown", "thumbs_down", "-1"] do
        assert {:ok, 1} = ReactionMapper.to_rating(provider, emoji)
      end

      assert {:ok, 1} = ReactionMapper.to_rating(:discord, "thumbsdown")
      assert {:ok, 1} = ReactionMapper.to_rating(:discord, "-1")
    end

    test "ignores short names for providers that do not define them" do
      assert :ignored = ReactionMapper.to_rating(:telegram, "thumbsup")
      assert :ignored = ReactionMapper.to_rating(:discord, "thumbs_up")
      assert :ignored = ReactionMapper.to_rating(:unknown, "+1")
    end
  end

  describe "to_rating/2 totality" do
    test "ignores unmapped emoji" do
      assert :ignored = ReactionMapper.to_rating(:mattermost, "tada")
      assert :ignored = ReactionMapper.to_rating(:mattermost, "\u{1F600}")
      assert :ignored = ReactionMapper.to_rating(:mattermost, "")
    end

    test "ignores malformed input instead of raising" do
      assert :ignored = ReactionMapper.to_rating(:mattermost, nil)
      assert :ignored = ReactionMapper.to_rating(:mattermost, %{name: "thumbsup"})
      assert :ignored = ReactionMapper.to_rating(:mattermost, 42)
      assert :ignored = ReactionMapper.to_rating("mattermost", "thumbsup")
      assert :ignored = ReactionMapper.to_rating(nil, nil)
    end
  end
end
