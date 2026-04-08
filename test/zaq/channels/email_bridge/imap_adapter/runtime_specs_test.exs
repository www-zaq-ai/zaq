defmodule Zaq.Channels.EmailBridge.ImapAdapter.RuntimeSpecsTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.EmailBridge.ImapAdapter

  test "runtime_specs/3 requires sink_mfa in opts" do
    config = %{
      id: 10,
      provider: "email:imap",
      settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}}
    }

    assert {:error, :missing_sink_mfa} = ImapAdapter.runtime_specs(config, "email:imap_10", [])
  end

  test "runtime_specs/3 uses sink_mfa from function args" do
    config = %{
      id: 11,
      provider: "email:imap",
      settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}}
    }

    sink_mfa = {Zaq.Channels.EmailBridge, :from_listener, []}

    assert {:ok, {nil, [listener_spec]}} =
             ImapAdapter.runtime_specs(config, "email:imap_11", sink_mfa: sink_mfa, sink_opts: [])

    {_, _, [listener_opts]} = listener_spec.start
    assert listener_opts[:sink_mfa] == sink_mfa
  end
end
