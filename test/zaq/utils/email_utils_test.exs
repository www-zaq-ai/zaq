defmodule Zaq.Utils.EmailUtilsTest do
  use ExUnit.Case, async: true

  alias Zaq.Utils.EmailUtils

  describe "normalize_message_id/1" do
    test "returns nil for nil" do
      assert EmailUtils.normalize_message_id(nil) == nil
    end

    test "strips angle brackets" do
      assert EmailUtils.normalize_message_id("<abc@example.com>") == "abc@example.com"
    end

    test "trims surrounding whitespace" do
      assert EmailUtils.normalize_message_id("  abc@example.com  ") == "abc@example.com"
    end

    test "returns nil for blank string" do
      assert EmailUtils.normalize_message_id("   ") == nil
    end

    test "returns nil for non-binary input (line 21)" do
      assert EmailUtils.normalize_message_id(123) == nil
      assert EmailUtils.normalize_message_id(:atom) == nil
    end
  end

  describe "new_message_id/1" do
    test "mints a bracket-less RFC-5322 addr-spec on the given domain" do
      id = EmailUtils.new_message_id("acme.test")

      assert id =~ ~r/^zaq-[0-9a-f-]{36}@acme\.test$/
      refute String.contains?(id, "<")
      refute String.contains?(id, ">")
    end

    test "is stored in the same normalized form the IMAP parser uses" do
      id = EmailUtils.new_message_id("acme.test")

      assert EmailUtils.normalize_message_id(id) == id
    end

    test "is unique across calls" do
      ids = for _ <- 1..50, do: EmailUtils.new_message_id("acme.test")

      assert length(Enum.uniq(ids)) == 50
    end

    test "falls back to the default domain for a blank or nil domain" do
      assert EmailUtils.new_message_id(nil) =~ ~r/@zaq\.local$/
      assert EmailUtils.new_message_id("  ") =~ ~r/@zaq\.local$/
    end
  end

  describe "sending_domain/2" do
    test "parses the domain from an email address" do
      assert EmailUtils.sending_domain("bot@acme.test") == "acme.test"
    end

    test "handles a display-name form" do
      assert EmailUtils.sending_domain("ZAQ Bot <bot@acme.test>") == "acme.test"
    end

    test "falls back when the address is nil, blank, or has no domain" do
      assert EmailUtils.sending_domain(nil) == "zaq.local"
      assert EmailUtils.sending_domain("   ") == "zaq.local"
      assert EmailUtils.sending_domain("not-an-email") == "zaq.local"
    end

    test "honors an explicit fallback" do
      assert EmailUtils.sending_domain(nil, "fallback.test") == "fallback.test"
    end
  end

  describe "normalize_references_list/1" do
    test "passes a list through, normalized" do
      assert EmailUtils.normalize_references_list(["<a@x>", "b@x"]) == ["a@x", "b@x"]
    end

    # Bug #1: the IMAP parser stores `references` as a space-joined STRING while
    # the outbound path stores a list. Every engine-side reader must coerce.
    test "splits a space-joined string (the inbound parser shape)" do
      assert EmailUtils.normalize_references_list("<a@x> <b@x>") == ["a@x", "b@x"]
    end

    test "returns [] for nil, blank, and non-list/binary input" do
      assert EmailUtils.normalize_references_list(nil) == []
      assert EmailUtils.normalize_references_list("   ") == []
      assert EmailUtils.normalize_references_list(123) == []
    end

    test "drops blanks and de-duplicates while preserving order" do
      assert EmailUtils.normalize_references_list(["a@x", "", "a@x", "b@x"]) == ["a@x", "b@x"]
    end
  end

  describe "build_thread_anchor/2" do
    test "builds the anchor with the references head as thread root" do
      assert EmailUtils.build_thread_anchor("<msg@x>", "<root@x> <mid@x>") == %{
               "message_id" => "msg@x",
               "thread_id" => "root@x",
               "references" => ["root@x", "mid@x"]
             }
    end

    test "a message without references roots its own thread" do
      assert EmailUtils.build_thread_anchor("msg@x", nil) == %{
               "message_id" => "msg@x",
               "thread_id" => "msg@x",
               "references" => []
             }
    end

    test "accepts the outbound list shape for references" do
      assert %{"thread_id" => "root@x"} =
               EmailUtils.build_thread_anchor("msg@x", ["<root@x>", "mid@x"])
    end

    test "returns nil without a Message-ID" do
      assert EmailUtils.build_thread_anchor(nil, "<root@x>") == nil
      assert EmailUtils.build_thread_anchor("  ", "<root@x>") == nil
      assert EmailUtils.build_thread_anchor(123, "<root@x>") == nil
    end
  end

  describe "cap_references/2" do
    # Bug #11: the thread root is derived from the references HEAD, so the cap
    # must always preserve the head or the derived root drifts.
    test "keeps the head (thread root) plus the last N when over the cap" do
      refs = for i <- 1..30, do: "id-#{i}@x"

      capped = EmailUtils.cap_references(refs, 5)

      assert length(capped) == 6
      assert hd(capped) == "id-1@x"
      assert List.last(capped) == "id-30@x"
      assert capped == ["id-1@x", "id-26@x", "id-27@x", "id-28@x", "id-29@x", "id-30@x"]
    end

    test "returns the chain untouched when under the cap" do
      assert EmailUtils.cap_references(["a@x", "b@x"], 20) == ["a@x", "b@x"]
    end

    test "returns [] for an empty chain" do
      assert EmailUtils.cap_references([], 20) == []
    end

    # Bug #1 regression: cap must tolerate the inbound parser's string shape.
    test "accepts a space-joined string input and returns a list" do
      assert EmailUtils.cap_references("<a@x> <b@x>", 20) == ["a@x", "b@x"]
    end

    test "tolerates nil" do
      assert EmailUtils.cap_references(nil, 20) == []
    end
  end
end
