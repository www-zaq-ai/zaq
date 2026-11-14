defmodule Zaq.WidgetTLSFixturesTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "creates a trusted TLS certificate under a long directory without changing caller cwd", %{
    tmp_dir: tmp_dir
  } do
    directory = Path.join(tmp_dir, String.duplicate("long-fixture-path-", 12)) |> Path.expand()
    File.mkdir_p!(directory)
    assert byte_size(Path.join(directory, "widget-ca.srl")) >= 256
    cwd = File.cwd!()

    tls = Zaq.WidgetTLSFixtures.certificates(directory)

    assert File.cwd!() == cwd

    for path <- [tls.keyfile, tls.certfile, tls.cacertfile] do
      assert Path.dirname(path) == directory
      assert File.stat!(path).size > 0
    end

    assert File.stat!(Path.join(directory, "widget-ca.srl")).size > 0

    assert {output, 0} =
             System.cmd(
               "openssl",
               [
                 "verify",
                 "-CAfile",
                 tls.cacertfile,
                 "-verify_hostname",
                 "localhost",
                 tls.certfile
               ],
               stderr_to_stdout: true
             )

    assert output =~ ": OK"
  end
end
