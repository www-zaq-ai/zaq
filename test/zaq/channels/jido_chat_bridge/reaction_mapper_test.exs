defmodule Zaq.Channels.JidoChatBridge.ReactionMapperTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.JidoChatBridge.ReactionMapper

  @mattermost_aliases [
    {"+1", 5},
    {"thumbsup", 5},
    {"thumbs_up", 5},
    {"-1", 1},
    {"thumbsdown", 1},
    {"thumbs_down", 1}
  ]
  @tone_suffixes [
    "",
    "_light_skin_tone",
    "_medium_light_skin_tone",
    "_medium_skin_tone",
    "_medium_dark_skin_tone",
    "_dark_skin_tone"
  ]

  describe "to_rating/2 Mattermost shortcodes" do
    test "maps paired-colon aliases and all five standard skin tones" do
      for {base, rating} <- @mattermost_aliases do
        assert ReactionMapper.to_rating(:mattermost, ":#{base}:") == {:ok, rating}
      end

      for suffix <- @tone_suffixes do
        assert {:ok, 5} = ReactionMapper.to_rating(:mattermost, "+1" <> suffix)
        assert {:ok, 1} = ReactionMapper.to_rating(:mattermost, ":-1#{suffix}:")
      end

      assert {:ok, 5} = ReactionMapper.to_rating(:mattermost, ":+1_medium_skin_tone:")
    end

    property "valid tone suffixes and paired delimiters preserve the base rating" do
      check all(
              {base, rating} <- member_of(@mattermost_aliases),
              suffix <- member_of(@tone_suffixes),
              delimiter <- member_of(["", ":"]),
              max_runs: 100
            ) do
        assert ReactionMapper.to_rating(:mattermost, delimiter <> base <> suffix <> delimiter) ==
                 {:ok, rating}
      end
    end

    test "ignores invalid suffixes, custom names, junk and malformed delimiters" do
      for emoji <- [
            "+1_medium_skin",
            "-1_blue_skin_tone",
            "thumbsup_skin_tone",
            "thumbs_up_medium_medium_skin_tone",
            "custom_+1_medium_skin_tone",
            "+1_medium_skin_tone_custom",
            "+1_medium_skin_tone_dark_skin_tone",
            ":+1",
            "+1:",
            ":-1_dark_skin_tone",
            "-1_dark_skin_tone:",
            "::+1::",
            ":+1:_medium_skin_tone",
            " +1",
            "+1\n",
            ":+1_medium_skin_tone:\n",
            "+1_medium_skin_tone\0",
            <<255>>
          ] do
        assert ReactionMapper.to_rating(:mattermost, emoji) == :ignored
      end
    end

    property "custom prefixes and trailing junk never become ratings" do
      check all(
              {base, _rating} <- member_of(@mattermost_aliases),
              suffix <- member_of(@tone_suffixes),
              junk <- string(:alphanumeric, min_length: 1, max_length: 16),
              max_runs: 100
            ) do
        assert :ignored = ReactionMapper.to_rating(:mattermost, junk <> "_" <> base <> suffix)
        assert :ignored = ReactionMapper.to_rating(:mattermost, base <> suffix <> "_" <> junk)
      end
    end

    test "does not extend other providers' shortcode mappings or Unicode forms" do
      for provider <- [:slack, :discord, :unknown], {base, _rating} <- @mattermost_aliases do
        assert :ignored = ReactionMapper.to_rating(provider, ":#{base}:")
        assert :ignored = ReactionMapper.to_rating(provider, base <> "_medium_skin_tone")
        assert :ignored = ReactionMapper.to_rating(provider, ":#{base}_medium_skin_tone:")
      end

      assert :ignored = ReactionMapper.to_rating(:mattermost, "\u{1F44D}\u{1F3FD}")
      assert :ignored = ReactionMapper.to_rating(:mattermost, "\u{1F44E}\u{1F3FD}")
    end
  end

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
