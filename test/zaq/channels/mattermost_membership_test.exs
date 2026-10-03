defmodule Zaq.Channels.MattermostMembershipTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.MattermostAdmin

  @room "abcde12345abcde12345abcde1"

  test "collects every validated page before marking the snapshot complete" do
    fetch = fn _config, room, page, per_page ->
      assert room == @room

      case page do
        0 -> {:ok, Enum.map(1..per_page, &%{"user_id" => "user-#{&1}"})}
        1 -> {:ok, [%{"user_id" => "user-1"}, %{"user_id" => "user-201"}]}
      end
    end

    assert {:ok, %{complete: true, member_ids: ids}} =
             MattermostAdmin.channel_membership_snapshot(%{}, @room, fetch_page: fetch)

    assert length(ids) == 201
    assert "user-201" in ids
  end

  test "rejects malformed page, failed middle page, and unbounded pagination without a partial revocation" do
    for bad <- [{:ok, [%{"user_id" => nil}]}, {:error, :offline}, {:ok, %{"error" => "no"}}] do
      fetch = fn _config, _room, page, per_page ->
        if page == 0,
          do: {:ok, Enum.map(1..per_page, &%{"user_id" => "user-#{&1}"})},
          else: bad
      end

      assert {:error, _} =
               MattermostAdmin.channel_membership_snapshot(%{}, @room, fetch_page: fetch)
    end

    endless = fn _config, _room, _page, per_page ->
      {:ok, Enum.map(1..per_page, &%{"user_id" => "user-#{&1}"})}
    end

    assert {:error, :snapshot_too_large} =
             MattermostAdmin.channel_membership_snapshot(%{}, @room, fetch_page: endless)

    assert {:error, :invalid_channel_id} =
             MattermostAdmin.channel_membership_snapshot(%{}, "../../users", fetch_page: endless)
  end

  property "complete member sets are deduplicated without losing any provider identity" do
    check all(
            ids <- list_of(string(:alphanumeric, min_length: 1, max_length: 16), max_length: 40)
          ) do
      fetch = fn _, _, _, _ -> {:ok, Enum.map(ids, &%{"user_id" => &1})} end

      assert {:ok, %{complete: true, member_ids: result}} =
               MattermostAdmin.channel_membership_snapshot(%{}, @room, fetch_page: fetch)

      assert result == ids |> Enum.uniq() |> Enum.sort()
    end
  end
end
