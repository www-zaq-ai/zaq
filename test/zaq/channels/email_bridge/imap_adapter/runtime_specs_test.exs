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

  test "runtime_specs/3 rejects malformed sink_mfa" do
    config = %{
      id: 12,
      provider: "email:imap",
      settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}}
    }

    assert {:error, :missing_sink_mfa} =
             ImapAdapter.runtime_specs(config, "email:imap_12",
               sink_mfa: {__MODULE__, :sink, :bad}
             )
  end

  test "listener_child_specs/2 applies fallback option parsing" do
    config = %{
      id: 13,
      provider: "email:imap",
      settings: %{
        "imap" => %{
          "selected_mailboxes" => ["INBOX"],
          "poll_interval" => "bad",
          "mark_as_read" => nil,
          "load_initial_unread" => "true",
          "idle_timeout" => "bad"
        }
      }
    }

    assert {:ok, [spec]} =
             ImapAdapter.listener_child_specs("email:imap_13",
               config: config,
               sink_mfa: {Zaq.Channels.EmailBridge, :from_listener, []},
               sink_opts: []
             )

    {_, _, [listener_opts]} = spec.start
    assert listener_opts[:retry_interval] == 30_000
    assert listener_opts[:mark_as_read] == true
    assert listener_opts[:load_initial_unread] == false
    assert listener_opts[:idle_timeout] == 1_500_000
  end

  test "listener_child_specs/2 returns missing_listener_options when required keys are absent" do
    assert {:error, :missing_listener_options} =
             ImapAdapter.listener_child_specs("email:imap_14", sink_opts: [])
  end
end
