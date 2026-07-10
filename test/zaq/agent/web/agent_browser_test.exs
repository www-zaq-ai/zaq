defmodule Zaq.Agent.Web.AgentBrowserTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Zaq.Agent.Web.AgentBrowser

  setup do
    prev_bin = System.get_env("AGENT_BROWSER_BIN")

    on_exit(fn ->
      if prev_bin,
        do: System.put_env("AGENT_BROWSER_BIN", prev_bin),
        else: System.delete_env("AGENT_BROWSER_BIN")
    end)

    :ok
  end

  # Writes a temporary executable and points AGENT_BROWSER_BIN at it so run/2
  # exercises the real Port path without a browser.
  defp fake_bin(body) do
    path =
      Path.join(System.tmp_dir!(), "agent_browser_fake_#{System.unique_integer([:positive])}")

    File.write!(path, body)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf(path) end)
    System.put_env("AGENT_BROWSER_BIN", path)
    path
  end

  # Prints each received argument on its own line — lets tests assert exact,
  # unsplit argument passing.
  defp echo_args_bin, do: fake_bin(~s(#!/bin/sh\nfor a in "$@"; do echo "$a"; done\n))

  describe "run/2 success" do
    test "returns joined stdout on exit 0" do
      echo_args_bin()

      assert {:ok, output} = AgentBrowser.run(["snapshot", "-i"])
      assert output =~ "snapshot"
      assert output =~ "-i"
    end

    test "passes each argument as a separate process arg (no shell interpretation)" do
      echo_args_bin()

      # A shell would split on the semicolon; spawn_executable must not.
      injection = "@e2; rm -rf /"
      assert {:ok, output} = AgentBrowser.run(["fill", injection])

      assert injection in String.split(output, "\n")
    end

    test "keeps output whose final line has no trailing newline" do
      # `printf` without a trailing \n arrives as a :noeol chunk; it must not be
      # dropped when the process exits.
      fake_bin("#!/bin/sh\nprintf 'no-newline-tail'\n")

      assert {:ok, "no-newline-tail"} = AgentBrowser.run(["snapshot"])
    end

    test "preserves an unterminated trailing line on a non-zero exit too" do
      fake_bin("#!/bin/sh\nprintf 'partial-error'\nexit 2\n")

      assert {:error, %{exit_code: 2, output: "partial-error"}} =
               AgentBrowser.run(["click", "@e1"])
    end
  end

  describe "run/2 failures" do
    test "maps a non-zero exit to an error tuple with the code and output" do
      fake_bin("#!/bin/sh\necho boom\nexit 3\n")

      assert {:error, %{exit_code: 3, output: output}} = AgentBrowser.run(["click", "@e1"])
      assert output =~ "boom"
    end

    test "returns :enoent when the binary is not found" do
      System.put_env("AGENT_BROWSER_BIN", "/nonexistent/agent-browser-xyz")

      assert {:error, %{exit_code: :enoent, output: output}} = AgentBrowser.run(["snapshot"])
      assert output =~ "not found"
    end

    test "returns :timeout when the command exceeds the timeout" do
      fake_bin("#!/bin/sh\nsleep 5\n")

      assert {:error, %{exit_code: :timeout}} = AgentBrowser.run(["open"], timeout_ms: 50)
    end
  end

  describe "configuration" do
    test "binary/0 prefers AGENT_BROWSER_BIN env over config default" do
      System.put_env("AGENT_BROWSER_BIN", "/custom/agent-browser")
      assert AgentBrowser.binary() == "/custom/agent-browser"
    end

    test "binary/0 falls back to the default when unset" do
      System.delete_env("AGENT_BROWSER_BIN")
      assert AgentBrowser.binary() == "agent-browser"
    end

    test "default_timeout_ms/0 returns a positive integer" do
      assert is_integer(AgentBrowser.default_timeout_ms())
      assert AgentBrowser.default_timeout_ms() > 0
    end
  end
end
