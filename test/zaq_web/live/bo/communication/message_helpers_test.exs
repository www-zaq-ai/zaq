defmodule ZaqWeb.Live.BO.Communication.MessageHelpersTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Live.BO.Communication.MessageHelpers

  describe "positive_rater_attrs/1" do
    test "returns anonymous attrs when current user is nil" do
      assert MessageHelpers.positive_rater_attrs(nil) == %{
               channel_user_id: "bo_anonymous",
               rating: 5
             }
    end
  end

  describe "negative_rater_attrs/3" do
    test "returns anonymous attrs and joined feedback fields when current user is nil" do
      attrs = MessageHelpers.negative_rater_attrs(nil, ["Not accurate"], "Missing context")

      assert attrs == %{
               channel_user_id: "bo_anonymous",
               rating: 1,
               comment: "Not accurate\nMissing context",
               feedback_reasons: ["Not accurate"]
             }
    end
  end
end
