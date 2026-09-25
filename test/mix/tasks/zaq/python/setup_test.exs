defmodule Mix.Tasks.Zaq.Python.SetupTest do
  use ExUnit.Case, async: false

  setup do
    original_path = System.get_env("PATH")
    original_output = System.get_env("ZAQ_TEST_PROVISION_ARGS")
    original_exit = System.get_env("ZAQ_TEST_PROVISION_EXIT")

    root =
      Path.join(System.tmp_dir!(), "zaq_python_setup_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    output = Path.join(root, "args")
    Mix.Task.reenable("cmd")
    System.put_env("PATH", root)
    System.put_env("ZAQ_TEST_PROVISION_ARGS", output)

    on_exit(fn ->
      restore_env("PATH", original_path)
      restore_env("ZAQ_TEST_PROVISION_ARGS", original_output)
      restore_env("ZAQ_TEST_PROVISION_EXIT", original_exit)
      File.rm_rf!(root)
    end)

    {:ok, root: root, output: output}
  end

  test "setup retains the existing bootstrap and provisions after fetching", %{
    root: root,
    output: output
  } do
    fake_python = Path.join(root, "python3.13")

    File.write!(
      fake_python,
      "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$ZAQ_TEST_PROVISION_ARGS\"\nexit 0\n"
    )

    File.chmod!(fake_python, 0o755)

    assert [
             "deps.get",
             "ecto.setup",
             "assets.setup",
             "assets.build",
             "zaq.python.fetch",
             provision
           ] = Mix.Project.config()[:aliases][:setup]

    assert is_function(provision, 1)
    provision.([])

    assert File.read!(output) ==
             "scripts/provision_python.py\npriv/python/crawler-ingest\n.venv\n"
  end

  test "setup fails when CPython 3.13 is unavailable" do
    provision = List.last(Mix.Project.config()[:aliases][:setup])

    assert_raise Mix.Error, ~r/CPython 3.13/, fn -> provision.([]) end
  end

  test "setup propagates provisioner failure", %{root: root} do
    fake_python = Path.join(root, "python3.13")
    File.write!(fake_python, "#!/bin/sh\nexit \"$ZAQ_TEST_PROVISION_EXIT\"\n")
    File.chmod!(fake_python, 0o755)
    System.put_env("ZAQ_TEST_PROVISION_EXIT", "17")

    provision = List.last(Mix.Project.config()[:aliases][:setup])

    assert catch_exit(provision.([])) == 17
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
