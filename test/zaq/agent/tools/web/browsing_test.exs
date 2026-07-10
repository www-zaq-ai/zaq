defmodule Zaq.Agent.Tools.Web.BrowsingTest do
  # async: false — mutates global env vars (AGENT_BROWSER_BIN,
  # AGENT_BROWSER_ALLOWED_DOMAINS, AGENT_BROWSER_TIMEOUT_MS); parallel tests
  # would collide on them.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Zaq.Agent.Tools.Web.Browsing

  setup do
    prev_bin = System.get_env("AGENT_BROWSER_BIN")
    prev_domains = System.get_env("AGENT_BROWSER_ALLOWED_DOMAINS")
    prev_timeout = System.get_env("AGENT_BROWSER_TIMEOUT_MS")

    on_exit(fn ->
      restore("AGENT_BROWSER_BIN", prev_bin)
      restore("AGENT_BROWSER_ALLOWED_DOMAINS", prev_domains)
      restore("AGENT_BROWSER_TIMEOUT_MS", prev_timeout)
    end)

    :ok
  end

  defp restore(var, nil), do: System.delete_env(var)
  defp restore(var, value), do: System.put_env(var, value)

  defp fake_bin(body) do
    path =
      Path.join(System.tmp_dir!(), "agent_browser_fake_#{System.unique_integer([:positive])}")

    File.write!(path, body)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf(path) end)
    System.put_env("AGENT_BROWSER_BIN", path)
    path
  end

  # Echoes each received argument on its own line so tests can assert the exact
  # argv the CLI was invoked with, end-to-end through the Port.
  defp echo_args_bin, do: fake_bin(~s(#!/bin/sh\nfor a in "$@"; do echo "$a"; done\n))

  defp argv({:ok, %{output: output}}), do: String.split(output, "\n", trim: true)

  describe "schema/0 and output_schema/0" do
    test "exposes the command surface" do
      keys = Keyword.keys(Browsing.schema())
      assert :command in keys
      assert :url in keys
      assert :selector in keys
      assert :text in keys
      assert :wait_for in keys
      assert :session in keys

      assert Keyword.keys(Browsing.output_schema()) == [:command, :output]
    end

    test "declares a react per-tool timeout above its per-command self-timeout" do
      # 60s default self-timeout + 30s headroom = 90s.
      assert Browsing.tool_timeout_ms() == 90_000
    end
  end

  describe "run/2 argument building" do
    setup do
      echo_args_bin()
      :ok
    end

    test "open passes the url and a session derived from the run id" do
      args = argv(Browsing.run(%{command: "open", url: "https://acme.test"}, %{run_id: "r1"}))

      assert "open" in args
      assert "https://acme.test" in args
      assert "--session" in args
      assert "r1" in args
    end

    test "open without a url still launches" do
      args = argv(Browsing.run(%{command: "open"}, %{}))
      assert "open" in args
      refute Enum.any?(args, &String.starts_with?(&1, "http"))
    end

    test "snapshot requests the ref-annotated tree and default session" do
      args = argv(Browsing.run(%{command: "snapshot"}, %{}))
      assert "snapshot" in args
      assert "-i" in args
      # default session when no run id present
      assert "zaq" in args
    end

    test "fill passes selector and text as separate args" do
      args =
        argv(
          Browsing.run(%{command: "fill", selector: "@e2", text: "me@acme.test"}, %{run_id: "r"})
        )

      assert "fill" in args
      assert "@e2" in args
      assert "me@acme.test" in args
    end

    test "press passes the key (form submit via Enter)" do
      args = argv(Browsing.run(%{command: "press", key: "Enter"}, %{}))
      assert "press" in args
      assert "Enter" in args
    end

    test "select passes selector and value" do
      args = argv(Browsing.run(%{command: "select", selector: "#country", value: "FR"}, %{}))
      assert ["select", "#country", "FR" | _] = args
    end

    test "an explicit session param overrides the context id" do
      args = argv(Browsing.run(%{command: "snapshot", session: "custom"}, %{run_id: "r1"}))
      assert "custom" in args
      refute "r1" in args
    end

    test "allowed_domains param adds the --allowed-domains flag" do
      args =
        argv(
          Browsing.run(
            %{command: "open", url: "https://acme.test", allowed_domains: "acme.test"},
            %{}
          )
        )

      assert "--allowed-domains" in args
      assert "acme.test" in args
    end

    test "allowed_domains falls back to the env var" do
      System.put_env("AGENT_BROWSER_ALLOWED_DOMAINS", "env.test")
      args = argv(Browsing.run(%{command: "snapshot"}, %{}))
      assert "--allowed-domains" in args
      assert "env.test" in args
    end

    test "wait passes a selector-or-milliseconds value" do
      args = argv(Browsing.run(%{command: "wait", wait_for: "3000"}, %{}))
      assert ["wait", "3000" | _] = args
    end

    test "text maps to the CLI `get text <selector>`" do
      args = argv(Browsing.run(%{command: "text", selector: "body"}, %{}))
      assert ["get", "text", "body" | _] = args
    end

    test "uncheck passes the selector" do
      args = argv(Browsing.run(%{command: "uncheck", selector: "#agree"}, %{}))
      assert ["uncheck", "#agree" | _] = args
    end

    test "url maps to the CLI `get url` (for verifying navigation)" do
      args = argv(Browsing.run(%{command: "url"}, %{}))
      assert ["get", "url" | _] = args
    end

    test "scrollintoview passes the selector" do
      args = argv(Browsing.run(%{command: "scrollintoview", selector: "@e5"}, %{}))
      assert ["scrollintoview", "@e5" | _] = args
    end

    test "type passes selector and text" do
      args =
        argv(Browsing.run(%{command: "type", selector: "@e3", text: "hello world"}, %{}))

      assert ["type", "@e3", "hello world" | _] = args
    end

    test "check passes the selector" do
      args = argv(Browsing.run(%{command: "check", selector: "#agree"}, %{}))
      assert ["check", "#agree" | _] = args
    end

    test "close builds the close command" do
      args = argv(Browsing.run(%{command: "close"}, %{}))
      assert "close" in args
    end

    test "an integer run id is stringified into the session" do
      args = argv(Browsing.run(%{command: "snapshot"}, %{run_id: 42}))
      assert "42" in args
    end

    test "a string-keyed run id in the context is honored" do
      args = argv(Browsing.run(%{command: "snapshot"}, %{"run_id" => "str-key"}))
      assert "str-key" in args
    end

    test "form-value text with shell metacharacters is passed intact" do
      injection = "a'; drop table; --"
      args = argv(Browsing.run(%{command: "fill", selector: "@e2", text: injection}, %{}))
      assert injection in args
    end
  end

  describe "run/2 validation" do
    test "rejects a command outside the allowlist without spawning" do
      # No fake bin set — a spawn would fail with :enoent; validation must short-circuit.
      System.put_env("AGENT_BROWSER_BIN", "/nonexistent/should-not-run")

      assert {:error, message} = Browsing.run(%{command: "eval"}, %{})
      assert message =~ "unsupported command: eval"
      assert message =~ "Allowed:"
    end

    test "reports a missing required argument" do
      System.put_env("AGENT_BROWSER_BIN", "/nonexistent/should-not-run")

      assert {:error, "fill requires: text"} =
               Browsing.run(%{command: "fill", selector: "@e2"}, %{})

      assert {:error, "click requires: selector"} = Browsing.run(%{command: "click"}, %{})
    end

    test "reports each missing required argument per command" do
      System.put_env("AGENT_BROWSER_BIN", "/nonexistent/should-not-run")

      assert {:error, "type requires: text"} =
               Browsing.run(%{command: "type", selector: "@e2"}, %{})

      assert {:error, "select requires: value"} =
               Browsing.run(%{command: "select", selector: "#c"}, %{})

      assert {:error, "press requires: key"} = Browsing.run(%{command: "press"}, %{})
      assert {:error, "check requires: selector"} = Browsing.run(%{command: "check"}, %{})
      assert {:error, "wait requires: wait_for"} = Browsing.run(%{command: "wait"}, %{})
      assert {:error, "text requires: selector"} = Browsing.run(%{command: "text"}, %{})

      assert {:error, "scrollintoview requires: selector"} =
               Browsing.run(%{command: "scrollintoview"}, %{})
    end

    test "a blank string argument is treated as missing" do
      System.put_env("AGENT_BROWSER_BIN", "/nonexistent/should-not-run")

      assert {:error, "click requires: selector"} =
               Browsing.run(%{command: "click", selector: "   "}, %{})
    end
  end

  describe "run/2 error mapping" do
    test "maps a CLI non-zero exit to a descriptive error" do
      fake_bin("#!/bin/sh\necho 'element not found'\nexit 4\n")

      assert {:error, message} = Browsing.run(%{command: "click", selector: "@e9"}, %{})
      assert message =~ "click failed (exit 4)"
      assert message =~ "element not found"
    end

    test "maps a missing binary to an install hint" do
      System.put_env("AGENT_BROWSER_BIN", "/nonexistent/agent-browser")

      assert {:error, message} = Browsing.run(%{command: "snapshot"}, %{})
      assert message =~ "agent-browser not installed"
    end

    test "maps a timeout" do
      fake_bin(~s(#!/bin/sh\nsleep 5\n))

      assert {:error, "open timed out"} =
               Browsing.run(%{command: "open", url: "https://slow.test", timeout_ms: 50}, %{})
    end

    test "honors AGENT_BROWSER_TIMEOUT_MS as the default timeout" do
      System.put_env("AGENT_BROWSER_TIMEOUT_MS", "60")
      fake_bin(~s(#!/bin/sh\nsleep 5\n))

      # No per-call timeout_ms → the env-derived default applies.
      assert {:error, "snapshot timed out"} = Browsing.run(%{command: "snapshot"}, %{})
    end
  end
end
