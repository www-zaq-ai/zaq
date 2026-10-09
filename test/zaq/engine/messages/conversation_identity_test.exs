defmodule Zaq.Engine.Messages.ConversationIdentityTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Messages.ConversationIdentity

  describe "channel_config_id/1" do
    test "returns nil for non-map identities" do
      assert ConversationIdentity.channel_config_id(nil) == nil
      assert ConversationIdentity.channel_config_id("123") == nil
    end

    test "accepts only positive integer channel configuration IDs" do
      assert ConversationIdentity.channel_config_id(%{"channel_config_id" => 7}) == 7
      assert ConversationIdentity.channel_config_id(%{"channel_config_id" => 0}) == nil
      assert ConversationIdentity.channel_config_id(%{"channel_config_id" => "7"}) == nil
      assert ConversationIdentity.channel_config_id(%{}) == nil
    end
  end
end
