defmodule Zaq.TestSupport.BrowserRuntimeSmokeTest do
  use ExUnit.Case, async: true

  @smoke Path.expand("bin/browser-runtime-smoke", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "browser-smoke-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    docker = Path.join(root, "docker")

    # Exercise orchestration only. The real-browser acceptance test never uses this double.
    File.write!(docker, """
    #!/bin/sh
    printf '%s\\n' "$*" >> "$PROBE_CALLS"
    case "$*" in
      *'AGENT_BROWSER_NATIVE=0'*open*) exit "${PROBE_DEFAULT_STATUS:-7}" ;;
      *'AGENT_BROWSER_NATIVE=0'*close*) exit 7 ;;
      *'printenv AGENT_BROWSER_NATIVE'*) printf '%s\\n' "${PROBE_NATIVE:-1}" ;;
      *'/usr/bin/chromium'*)
        [ "${PROBE_FAILURE:-}" != chromium ] || exit 124
        printf '<html><head></head><body></body></html>\\n' ;;
      *'open about:blank'*) [ "${PROBE_FAILURE:-}" != open ] || exit 124 ;;
      *'get url'*) printf '%s\\n' "${PROBE_URL:-about:blank}" ;;
      *'close --session'*native*) [ "${PROBE_FAILURE:-}" != close ] || exit 8 ;;
    esac
    """)

    File.chmod!(docker, 0o700)

    {:ok,
     env: [
       {"PATH", root},
       {"ZAQ_BROWSER_CONTAINER", "test-browser"},
       {"PROBE_CALLS", Path.join(root, "calls")}
     ]}
  end

  test "checks raw launch and native navigation despite a failed default-backend probe",
       context do
    assert {output, 0} = run_probe(context)
    assert output =~ "Default backend probe exit: 7"
    calls = context.env |> List.keyfind("PROBE_CALLS", 0) |> elem(1) |> File.read!()
    assert calls =~ "timeout --kill-after=5s 20s /usr/bin/chromium"
    assert calls =~ "env AGENT_BROWSER_NATIVE=0 /usr/local/bin/agent-browser"
    assert calls =~ "get url --session zaq-smoke-native-"
    assert calls =~ "close --session zaq-smoke-native-"
    refute calls =~ "--allowed-domains"
    refute calls =~ "top test-browser"
  end

  test "rejects an image that does not select the native backend", context do
    assert {output, 1} = run_probe(context, [{"PROBE_NATIVE", "0"}])
    assert output =~ "Expected AGENT_BROWSER_NATIVE=1"
  end

  test "also accepts a Cargo binary with a working default backend", context do
    assert {output, 0} = run_probe(context, [{"PROBE_DEFAULT_STATUS", "0"}])
    assert output =~ "Default backend probe exit: 0"
  end

  test "propagates raw Chromium and browser command failures and still cleans up", context do
    for stage <- ["chromium", "open", "close"] do
      calls_path = context.env |> List.keyfind("PROBE_CALLS", 0) |> elem(1)
      File.write!(calls_path, "")
      assert {_output, status} = run_probe(context, [{"PROBE_FAILURE", stage}])
      assert status != 0
      calls = File.read!(calls_path)
      assert calls =~ "top test-browser -eo pid,ppid,user,stat,comm"

      if stage == "chromium" do
        refute calls =~ "close --session zaq-smoke-native-"
      else
        assert calls =~ "close --session zaq-smoke-native-"
      end

      assert calls =~ "rm -rf /tmp/zaq-smoke-chromium-"
    end
  end

  test "rejects a successful command without the expected navigation effect", context do
    assert {output, 1} = run_probe(context, [{"PROBE_URL", "unexpected"}])
    assert output =~ "Expected about:blank"
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
