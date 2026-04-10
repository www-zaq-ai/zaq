defmodule Zaq.People.IdentityPlugTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Accounts.Person
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.People.IdentityPlug

  alias Zaq.People.IdentityPlugTest.StubRouterDmOk
  alias Zaq.People.IdentityPlugTest.StubRouterError
  alias Zaq.People.IdentityPlugTest.StubRouterOk
  alias Zaq.People.IdentityPlugTest.StubRouterRaise
  alias Zaq.People.IdentityPlugTest.StubRouterStringKeys
  alias Zaq.People.IdentityPlugTest.StubRouterTimeout

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp incoming(overrides) do
    struct(
      %Incoming{
        content: "hello",
        channel_id: "C123",
        provider: :slack,
        author_id: "U123",
        author_name: "jane"
      },
      overrides
    )
  end

  defp create_complete_person do
    {:ok, person} =
      People.create_person(%{
        full_name: "Jane Smith",
        email: "jane@example.com",
        phone: "+1555000"
      })

    {:ok, _channel} =
      People.add_channel(%{
        "person_id" => person.id,
        "platform" => "slack",
        "channel_identifier" => "U123"
      })

    People.get_person_with_channels!(person.id)
  end

  defp create_incomplete_person do
    {:ok, person} = People.create_person(%{full_name: "U456", incomplete: true})

    {:ok, _channel} =
      People.add_channel(%{
        "person_id" => person.id,
        "platform" => "slack",
        "channel_identifier" => "U456"
      })

    People.get_person_with_channels!(person.id)
  end

  # ── Fast path ────────────────────────────────────────────────────────────

  describe "call/2 fast path" do
    test "sets person_id when author matches a complete person" do
      person = create_complete_person()
      msg = incoming(%{author_id: "U123", provider: :slack})

      result = IdentityPlug.call(msg, channels_router: StubRouterRaise)

      assert result.person_id == person.id
    end

    test "does not call channels router for complete persons" do
      create_complete_person()
      msg = incoming(%{author_id: "U123", provider: :slack})

      # StubRouterRaise raises if called — verifies fast path skips enrichment.
      result = IdentityPlug.call(msg, channels_router: StubRouterRaise)

      refute is_nil(result.person_id)
    end
  end

  # ── Slow path ───────────────────────────────────────────────────────────

  describe "call/2 slow path" do
    test "creates a partial person when no match exists" do
      msg = incoming(%{author_id: "U_new", author_name: "newuser", provider: :slack})

      result = IdentityPlug.call(msg, channels_router: StubRouterError)

      refute is_nil(result.person_id)
      person = People.get_person_with_channels!(result.person_id)
      assert person.incomplete == true
      assert Enum.any?(person.channels, &(&1.channel_identifier == "U_new"))
    end

    test "enriches with profile data when router returns a profile" do
      msg = incoming(%{author_id: "U_new2", provider: :slack})

      result = IdentityPlug.call(msg, channels_router: StubRouterOk)

      refute is_nil(result.person_id)
      person = People.get_person_with_channels!(result.person_id)
      assert person.full_name == "Enriched Name"
    end

    test "still resolves when profile enrichment fails" do
      create_incomplete_person()
      msg = incoming(%{author_id: "U456", provider: :slack})

      result = IdentityPlug.call(msg, channels_router: StubRouterTimeout)

      refute is_nil(result.person_id)
    end
  end

  # ── touch_channel branches ───────────────────────────────────────────────

  describe "call/2 touch_channel" do
    test "records interaction when fast-path channel already has dm_channel_id" do
      # Create person whose channel already has dm_channel_id set — the plug
      # should record an interaction instead of updating dm_channel_id.
      # person needs full_name + email + phone so put_incomplete_flag sets incomplete: false.
      {:ok, person} =
        People.create_person(%{
          full_name: "Already DM",
          email: "alreadydm@example.com",
          phone: "+15550001"
        })

      {:ok, channel} =
        People.add_channel(%{
          "person_id" => person.id,
          "platform" => "slack",
          "channel_identifier" => "U_DM_SET"
        })

      {:ok, _} = People.update_channel(channel, %{dm_channel_id: "DM_EXISTING"})

      msg = incoming(%{author_id: "U_DM_SET", provider: :slack, channel_id: "DM_NEW"})
      result = IdentityPlug.call(msg, channels_router: StubRouterRaise)

      refute is_nil(result.person_id)
    end

    test "records interaction when message channel_id is nil (no dm_channel_id to backfill)" do
      # channel_id nil → canonical dm_channel_id nil → touch_channel/2 fallback clause
      {:ok, person} =
        People.create_person(%{
          full_name: "NoDM Person",
          email: "nodm@example.com",
          phone: "+15550002"
        })

      {:ok, _channel} =
        People.add_channel(%{
          "person_id" => person.id,
          "platform" => "slack",
          "channel_identifier" => "U_NODM"
        })

      msg = incoming(%{author_id: "U_NODM", provider: :slack, channel_id: nil})
      result = IdentityPlug.call(msg, channels_router: StubRouterRaise)

      refute is_nil(result.person_id)
    end

    test "handles string-keyed profile from channels router (stringify_profile)" do
      # StubRouterStringKeys returns a map with string keys — exercises the
      # {k, v} -> {k, v} branch in stringify_profile/1.
      msg = incoming(%{author_id: "U_STR_KEYS", provider: :slack})

      result = IdentityPlug.call(msg, channels_router: StubRouterStringKeys)

      refute is_nil(result.person_id)
      person = People.get_person_with_channels!(result.person_id)
      assert person.full_name == "String Key Name"
    end
  end

  # ── maybe_backfill_dm_channel branches ──────────────────────────────────

  describe "call/2 maybe_backfill_dm_channel" do
    test "skips DM backfill when message is_dm: true (fast path)" do
      # DM message → maybe_backfill_dm_channel returns :ok immediately.
      # StubRouterRaise would blow up if open_dm_channel were called.
      {:ok, person} =
        People.create_person(%{
          full_name: "DM Skip",
          email: "dmskip@example.com",
          phone: "+15550010"
        })

      {:ok, _} =
        People.add_channel(%{
          "person_id" => person.id,
          "platform" => "slack",
          "channel_identifier" => "U_DM_SKIP"
        })

      msg =
        incoming(%{
          author_id: "U_DM_SKIP",
          provider: :slack,
          is_dm: true,
          channel_id: "DM_CH_SKIP"
        })

      result = IdentityPlug.call(msg, channels_router: StubRouterRaise)

      refute is_nil(result.person_id)
    end

    test "backfills dm_channel_id via open_dm_channel on fast path (non-DM message)" do
      # Complete person, non-DM message, channel has no dm_channel_id yet.
      # StubRouterDmOk.open_dm_channel returns {:ok, "DM_BACKFILLED"} → channel updated.
      {:ok, person} =
        People.create_person(%{
          full_name: "Backfill Person",
          email: "backfill@example.com",
          phone: "+15550020"
        })

      {:ok, channel} =
        People.add_channel(%{
          "person_id" => person.id,
          "platform" => "slack",
          "channel_identifier" => "U_BACKFILL"
        })

      assert is_nil(channel.dm_channel_id)

      msg = incoming(%{author_id: "U_BACKFILL", provider: :slack, is_dm: false})
      result = IdentityPlug.call(msg, channels_router: StubRouterDmOk)

      refute is_nil(result.person_id)
      updated = People.get_person_with_channels!(result.person_id)
      ch = Enum.find(updated.channels, &(&1.channel_identifier == "U_BACKFILL"))
      assert ch.dm_channel_id == "DM_BACKFILLED"
    end

    test "backfills dm_channel_id via open_dm_channel on slow path (non-DM message)" do
      # New person (slow path), non-DM message, open_dm_channel returns {:ok, ...}.
      msg = incoming(%{author_id: "U_SLOW_BACKFILL", provider: :slack, is_dm: false})
      result = IdentityPlug.call(msg, channels_router: StubRouterDmOk)

      refute is_nil(result.person_id)
    end
  end

  # ── touch_channel DM path ────────────────────────────────────────────────

  describe "call/2 touch_channel DM path" do
    test "sets dm_channel_id when is_dm: true and channel has none" do
      # DM message with channel_id = the DM channel → touch_channel sees a binary
      # dm_channel_id and channel.dm_channel_id is nil → calls update_channel.
      {:ok, person} =
        People.create_person(%{
          full_name: "DM Update",
          email: "dmupdate@example.com",
          phone: "+15550030"
        })

      {:ok, channel} =
        People.add_channel(%{
          "person_id" => person.id,
          "platform" => "slack",
          "channel_identifier" => "U_DM_UPDATE"
        })

      assert is_nil(channel.dm_channel_id)

      msg =
        incoming(%{
          author_id: "U_DM_UPDATE",
          provider: :slack,
          is_dm: true,
          channel_id: "DM_CH_001"
        })

      # StubRouterRaise: open_dm_channel won't be called because is_dm: true
      result = IdentityPlug.call(msg, channels_router: StubRouterRaise)

      refute is_nil(result.person_id)
      updated = People.get_person_with_channels!(result.person_id)
      ch = Enum.find(updated.channels, &(&1.channel_identifier == "U_DM_UPDATE"))
      assert ch.dm_channel_id == "DM_CH_001"
    end

    test "records interaction when is_dm: true and channel already has dm_channel_id" do
      # DM message, channel already has dm_channel_id → touch_channel records interaction
      # instead of overwriting it, and maybe_backfill_dm_channel is skipped (is_dm: true).
      {:ok, person} =
        People.create_person(%{
          full_name: "DM Already Set",
          email: "dmalready@example.com",
          phone: "+15550040"
        })

      {:ok, channel} =
        People.add_channel(%{
          "person_id" => person.id,
          "platform" => "slack",
          "channel_identifier" => "U_DM_ALREADY"
        })

      {:ok, _} = People.update_channel(channel, %{dm_channel_id: "DM_ORIGINAL"})

      msg =
        incoming(%{
          author_id: "U_DM_ALREADY",
          provider: :slack,
          is_dm: true,
          channel_id: "DM_NEW_ATTEMPT"
        })

      result = IdentityPlug.call(msg, channels_router: StubRouterRaise)

      refute is_nil(result.person_id)
      # dm_channel_id must NOT be overwritten
      updated = People.get_person_with_channels!(result.person_id)
      ch = Enum.find(updated.channels, &(&1.channel_identifier == "U_DM_ALREADY"))
      assert ch.dm_channel_id == "DM_ORIGINAL"
    end
  end

  # ── IMAP email resolution ────────────────────────────────────────────────

  describe "call/2 email:imap" do
    test "resolves to existing person by email (no prior PersonChannel)" do
      {:ok, person} =
        People.create_person(%{
          full_name: "Jad Tarabay",
          email: "j.tarabay@zaq.ai"
        })

      msg = incoming(%{provider: :"email:imap", author_id: "j.tarabay@zaq.ai"})

      before_count = Repo.aggregate(Person, :count, :id)
      result = IdentityPlug.call(msg, channels_router: StubRouterError)
      after_count = Repo.aggregate(Person, :count, :id)

      assert result.person_id == person.id
      assert before_count == after_count
      resolved = People.get_person_with_channels!(result.person_id)
      assert resolved.email == "j.tarabay@zaq.ai"
    end
  end

  # ── Edge cases ───────────────────────────────────────────────────────────

  describe "call/2 edge cases" do
    test "returns message unchanged when author_id is nil" do
      msg = incoming(%{author_id: nil})

      result = IdentityPlug.call(msg, channels_router: StubRouterRaise)

      assert result.person_id == nil
    end

    test "returns message unchanged when all resolution fails" do
      # Simulate a bad platform where the channel insertion fails (empty channel_id
      # after normalization causes add_channel to reject). person_id stays nil.
      msg = incoming(%{author_id: nil, provider: :unknown})

      result = IdentityPlug.call(msg, channels_router: StubRouterRaise)

      assert result.person_id == nil
    end
  end
end
