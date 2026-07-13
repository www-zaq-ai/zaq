defmodule Zaq.Channels.EmailBridge.MessageIdCollisionTest do
  @moduledoc """
  Bug #4 guard: our minted `Message-ID` must be the one actually delivered — not
  duplicated, not overridden by the adapter.

  This asserts on the **mimemail-encoded payload**, not on the `%Swoosh.Email{}`
  struct. The test and local adapters never run mimemail, so a struct-level
  assertion would pass trivially and prove nothing about adapter injection.

  gen_smtp's `mimemail:check_headers/2` fills in a `Message-ID` only when one is
  absent (`mimemail.erl:693`), so an explicitly-set header survives. This test
  pins that behaviour so a dep upgrade can't silently flip it.
  """
  use ExUnit.Case, async: true

  import Swoosh.Email

  alias Swoosh.Adapters.SMTP.Helpers

  defp encode(email) do
    email
    |> Helpers.body([])
    |> IO.iodata_to_binary()
  end

  defp message_id_headers(encoded) do
    encoded
    |> String.split(~r/\r?\n/)
    |> Enum.filter(&String.match?(&1, ~r/^Message-ID:/i))
  end

  defp base_email do
    new()
    |> from({"ZAQ", "bot@acme.test"})
    |> to("lead@example.test")
    |> subject("Topic A")
    |> text_body("hello")
  end

  test "our minted Message-ID is delivered, exactly once" do
    encoded =
      base_email()
      |> header("Message-ID", "<zaq-minted@acme.test>")
      |> encode()

    headers = message_id_headers(encoded)

    assert length(headers) == 1
    assert hd(headers) =~ "<zaq-minted@acme.test>"
  end

  test "the adapter only mints its own Message-ID when we supply none" do
    encoded = base_email() |> encode()

    # gen_smtp fills one in — which is exactly why we must set ours explicitly.
    assert length(message_id_headers(encoded)) == 1
    refute encoded =~ "zaq-minted@acme.test"
  end

  test "In-Reply-To and References survive encoding alongside our Message-ID" do
    encoded =
      base_email()
      |> header("Message-ID", "<zaq-new@acme.test>")
      |> header("In-Reply-To", "<m1@acme.test>")
      |> header("References", "<m0@acme.test> <m1@acme.test>")
      |> encode()

    assert length(message_id_headers(encoded)) == 1
    assert encoded =~ "<zaq-new@acme.test>"
    assert encoded =~ "In-Reply-To: <m1@acme.test>"
    assert encoded =~ "References: <m0@acme.test> <m1@acme.test>"
  end
end
