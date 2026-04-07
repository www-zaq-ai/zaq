defmodule Zaq.People.IdentityPlugTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.People.IdentityPlug

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp incoming(overrides \\ %{}) do
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

  # ── Edge cases ───────────────────────────────────────────────────────────

  describe "call/2 edge cases" do
    test "returns message unchanged when author_id is nil" do
      msg = incoming(%{author_id: nil})

      result = IdentityPlug.call(msg, channels_router: StubRouterRaise)

      assert result.person_id == nil
    end

    test "returns message unchanged when channel_id is empty after normalization" do
      # Empty author_id normalizes to empty channel_id, which match_by_channel rejects.
      msg = incoming(%{author_id: "", provider: :unknown})

      result = IdentityPlug.call(msg, channels_router: StubRouterError)

      assert result.person_id == nil
    end
  end
end

# ── Stub router modules ───────────────────────────────────────────────────
# Static modules are required — closures cannot be used with Module.create/Macro.escape.

defmodule StubRouterOk do
  @moduledoc false
  def fetch_profile(_platform, _author_id) do
    {:ok, %{display_name: "Enriched Name", email: "enriched@example.com"}}
  end
end

defmodule StubRouterError do
  @moduledoc false
  def fetch_profile(_platform, _author_id), do: {:error, :not_found}
end

defmodule StubRouterTimeout do
  @moduledoc false
  def fetch_profile(_platform, _author_id), do: {:error, :timeout}
end

defmodule StubRouterRaise do
  @moduledoc false
  def fetch_profile(_platform, _author_id) do
    raise "channels router should not have been called on the fast path"
  end
end
