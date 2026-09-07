defmodule Zaq.TestSupport.BrowserContainerWrapperTest do
  use ExUnit.Case, async: true

  @wrapper Path.expand("bin/agent-browser-container", __DIR__)

  test "forwards command arguments unchanged to docker exec" do
    root = Path.join(System.tmp_dir!(), "browser-wrapper-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    docker = Path.join(root, "docker")
    # Observe transport argv only; this does not supply browser responses.
    File.write!(docker, "#!/bin/sh\nprintf '%s\\000' \"$@\"\n")
    File.chmod!(docker, 0o700)

    arguments = [
      "fill",
      "#message",
      "Ada & QA; $(not-a-command)\nsecond line",
      "--session",
      "unique-session"
    ]

    assert {output, 0} =
             System.cmd("sh", [@wrapper | arguments],
               env: [{"PATH", root}, {"ZAQ_BROWSER_CONTAINER", "test-container"}]
             )

    assert String.split(output, <<0>>, trim: true) ==
             ["exec", "test-container", "/usr/local/bin/agent-browser" | arguments]
  end

  test "fails clearly without a container name" do
    assert {output, status} =
             System.cmd("sh", [@wrapper, "--version"],
               env: [{"ZAQ_BROWSER_CONTAINER", nil}],
               stderr_to_stdout: true
             )

    assert status != 0
    assert output =~ "Set ZAQ_BROWSER_CONTAINER"
  end
end
