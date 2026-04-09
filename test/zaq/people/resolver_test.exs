defmodule Zaq.People.ResolverTest do
  use ExUnit.Case, async: true

  alias Zaq.People.Resolver

  # ── slack ────────────────────────────────────────────────────────────────

  describe "normalize/2 - slack" do
    test "maps user_id, handle, full_name, email, dm_channel_id (atom keys)" do
      attrs = %{
        user_id: "U123",
        handle: "jane",
        full_name: "Jane Doe",
        email: "jane@example.com",
        dm_channel_id: "DM123"
      }

      result = Resolver.normalize("slack", attrs)

      assert result["channel_id"] == "U123"
      assert result["username"] == "jane"
      assert result["display_name"] == "Jane Doe"
      assert result["email"] == "jane@example.com"
      assert result["dm_channel_id"] == "DM123"
    end

    test "falls back to channel_id / username when primary fields absent" do
      attrs = %{channel_id: "fallback_id", username: "fallback_user"}
      result = Resolver.normalize("slack", attrs)

      assert result["channel_id"] == "fallback_id"
      assert result["username"] == "fallback_user"
    end

    test "accepts string keys" do
      attrs = %{"user_id" => "U456", "handle" => "bob", "email" => "bob@example.com"}
      result = Resolver.normalize("slack", attrs)

      assert result["channel_id"] == "U456"
      assert result["username"] == "bob"
      assert result["email"] == "bob@example.com"
    end
  end

  # ── mattermost ───────────────────────────────────────────────────────────

  describe "normalize/2 - mattermost" do
    test "behaves identically to slack" do
      attrs = %{user_id: "MM1", handle: "mm_user", full_name: "MM User"}

      assert Resolver.normalize("mattermost", attrs) == Resolver.normalize("slack", attrs)
    end
  end

  # ── microsoft_teams ──────────────────────────────────────────────────────

  describe "normalize/2 - microsoft_teams" do
    test "maps azure_ad_id, email, full_name" do
      attrs = %{azure_ad_id: "AAD1", email: "user@corp.com", full_name: "Corp User"}
      result = Resolver.normalize("microsoft_teams", attrs)

      assert result["channel_id"] == "AAD1"
      assert result["username"] == "user@corp.com"
      assert result["display_name"] == "Corp User"
      assert result["email"] == "user@corp.com"
    end

    test "falls back to channel_id when azure_ad_id absent" do
      attrs = %{channel_id: "fallback_id", email: "user@corp.com"}
      result = Resolver.normalize("microsoft_teams", attrs)

      assert result["channel_id"] == "fallback_id"
    end

    test "falls back to username when email absent" do
      attrs = %{azure_ad_id: "AAD2", username: "fallback_user"}
      result = Resolver.normalize("microsoft_teams", attrs)

      assert result["username"] == "fallback_user"
    end

    test "falls back to display_name when full_name absent" do
      attrs = %{azure_ad_id: "AAD3", display_name: "Display Name"}
      result = Resolver.normalize("microsoft_teams", attrs)

      assert result["display_name"] == "Display Name"
    end
  end

  # ── whatsapp ─────────────────────────────────────────────────────────────

  describe "normalize/2 - whatsapp" do
    test "uses phone as channel_id" do
      attrs = %{phone: "+15551234567"}
      result = Resolver.normalize("whatsapp", attrs)

      assert result["channel_id"] == "+15551234567"
      assert result["phone"] == "+15551234567"
    end

    test "falls back to channel_id when phone absent" do
      attrs = %{channel_id: "+15559999999"}
      result = Resolver.normalize("whatsapp", attrs)

      assert result["channel_id"] == "+15559999999"
      assert result["phone"] == "+15559999999"
    end
  end

  # ── telegram ─────────────────────────────────────────────────────────────

  describe "normalize/2 - telegram" do
    test "builds display_name from first_name and last_name" do
      attrs = %{chat_id: "T1", first_name: "John", last_name: "Doe", handle: "@johndoe"}
      result = Resolver.normalize("telegram", attrs)

      assert result["channel_id"] == "T1"
      assert result["username"] == "@johndoe"
      assert result["display_name"] == "John Doe"
    end

    test "uses only first_name when last_name absent" do
      attrs = %{chat_id: "T2", first_name: "Alice"}
      result = Resolver.normalize("telegram", attrs)

      assert result["display_name"] == "Alice"
    end

    test "falls back to display_name when both name parts are empty" do
      attrs = %{chat_id: "T3", display_name: "Fallback Name"}
      result = Resolver.normalize("telegram", attrs)

      assert result["display_name"] == "Fallback Name"
    end

    test "falls back to channel_id when chat_id absent" do
      attrs = %{channel_id: "T4", first_name: "Bob"}
      result = Resolver.normalize("telegram", attrs)

      assert result["channel_id"] == "T4"
    end

    test "falls back to username when handle absent" do
      attrs = %{chat_id: "T5", username: "fallback_handle"}
      result = Resolver.normalize("telegram", attrs)

      assert result["username"] == "fallback_handle"
    end
  end

  # ── discord ──────────────────────────────────────────────────────────────

  describe "normalize/2 - discord" do
    test "combines name and discriminator into username" do
      attrs = %{snowflake: "D1", name: "jane", discriminator: "1234", nickname: "Jane In Server"}
      result = Resolver.normalize("discord", attrs)

      assert result["channel_id"] == "D1"
      assert result["username"] == "jane#1234"
      assert result["display_name"] == "Jane In Server"
    end

    test "uses name alone when discriminator absent" do
      attrs = %{snowflake: "D2", name: "bob_only"}
      result = Resolver.normalize("discord", attrs)

      assert result["username"] == "bob_only"
    end

    test "falls back to username attr when name absent" do
      attrs = %{snowflake: "D3", username: "fallback_user"}
      result = Resolver.normalize("discord", attrs)

      assert result["username"] == "fallback_user"
    end

    test "falls back to display_name when nickname absent" do
      attrs = %{snowflake: "D4", display_name: "Fallback Display"}
      result = Resolver.normalize("discord", attrs)

      assert result["display_name"] == "Fallback Display"
    end

    test "falls back to channel_id when snowflake absent" do
      attrs = %{channel_id: "D5"}
      result = Resolver.normalize("discord", attrs)

      assert result["channel_id"] == "D5"
    end
  end

  # ── email ────────────────────────────────────────────────────────────────

  describe "normalize/2 - email" do
    test "uses email as channel_id" do
      attrs = %{email: "user@example.com", display_name: "Email User"}
      result = Resolver.normalize("email", attrs)

      assert result["channel_id"] == "user@example.com"
      assert result["email"] == "user@example.com"
      assert result["display_name"] == "Email User"
    end

    test "falls back to channel_id when email absent" do
      attrs = %{channel_id: "fallback@example.com"}
      result = Resolver.normalize("email", attrs)

      assert result["channel_id"] == "fallback@example.com"
      assert result["email"] == "fallback@example.com"
    end
  end

  # ── email:imap ───────────────────────────────────────────────────────────

  describe "normalize/2 - email:imap" do
    test "maps channel_id into both channel_id and email" do
      attrs = %{channel_id: "sender@example.com"}
      result = Resolver.normalize("email:imap", attrs)

      assert result["channel_id"] == "sender@example.com"
      assert result["email"] == "sender@example.com"
    end

    test "prefers explicit email over channel_id" do
      attrs = %{email: "sender@example.com", channel_id: "other_id"}
      result = Resolver.normalize("email:imap", attrs)

      assert result["channel_id"] == "sender@example.com"
      assert result["email"] == "sender@example.com"
    end

    test "delegates to email normalizer (identical result)" do
      attrs = %{channel_id: "imap@example.com", display_name: "IMAP User"}

      assert Resolver.normalize("email:imap", attrs) == Resolver.normalize("email", attrs)
    end
  end

  # ── fallback ─────────────────────────────────────────────────────────────

  describe "normalize/2 - unknown platform" do
    test "passes all fields through" do
      attrs = %{
        channel_id: "C1",
        username: "user1",
        display_name: "User One",
        email: "u@example.com",
        phone: "+1234"
      }

      result = Resolver.normalize("custom_platform", attrs)

      assert result["channel_id"] == "C1"
      assert result["username"] == "user1"
      assert result["display_name"] == "User One"
      assert result["email"] == "u@example.com"
      assert result["phone"] == "+1234"
    end
  end
end
