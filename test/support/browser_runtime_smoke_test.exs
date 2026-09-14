defmodule Zaq.TestSupport.BrowserRuntimeSmokeTest do
  use ExUnit.Case, async: true

  @smoke Path.expand("bin/browser-runtime-smoke", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "browser-smoke-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    docker = Path.join(root, "docker")
    calls = Path.join(root, "calls")

    # Only transport orchestration is doubled; the integration browser stays real.
    File.write!(docker, """
    #!/bin/sh
    printf '%s\\n' "$*" >> "$PROBE_CALLS"
    case "$*" in
      *'/usr/bin/chromium'*)
        printf '<html><head></head><body></body></html>\\n'
        exit "${PROBE_STATUS:-0}" ;;
    esac
    """)

    File.chmod!(docker, 0o700)

    {:ok,
     calls: calls,
     env: [{"PATH", root}, {"ZAQ_BROWSER_CONTAINER", "test-browser"}, {"PROBE_CALLS", calls}]}
  end

  test "checks raw Chromium without starting a CLI session or another server", context do
    assert {output, 0} = run_probe(context)
    assert output =~ "<html>"
    calls = File.read!(context.calls)
    assert calls =~ "timeout --kill-after=5s 20s /usr/bin/chromium"
    assert calls =~ "--dump-dom about:blank"
    assert calls =~ "rm -rf /tmp/zaq-smoke-chromium-"
    refute calls =~ "/usr/local/bin/agent-browser"
    refute calls =~ "AGENT_BROWSER_NATIVE"
    refute calls =~ "python"
    refute calls =~ "top test-browser"
  end

  test "preserves launch failures and timeouts while inspecting and cleaning up", context do
    for status <- [1, 124] do
      File.write!(context.calls, "")
      assert {_output, ^status} = run_probe(context, [{"PROBE_STATUS", to_string(status)}])
      calls = File.read!(context.calls)
      assert calls =~ "top test-browser -eo pid,ppid,user,stat,comm"
      assert calls =~ "rm -rf /tmp/zaq-smoke-chromium-"
      refute calls =~ "/usr/local/bin/agent-browser"
    end
  end

  test "requires an explicit container", context do
    assert {output, status} = run_probe(context, [{"ZAQ_BROWSER_CONTAINER", nil}])
    assert status != 0
    assert output =~ "Set ZAQ_BROWSER_CONTAINER"
  end

  defp run_probe(context, overrides \\ []) do
    System.cmd("/bin/sh", [@smoke], env: context.env ++ overrides, stderr_to_stdout: true)
  end
end
