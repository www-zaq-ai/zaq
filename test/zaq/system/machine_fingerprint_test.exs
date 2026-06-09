defmodule Zaq.System.MachineFingerprintTest do
  use ExUnit.Case, async: false

  alias Zaq.System.MachineFingerprint

  test "returns a 32-character fingerprint" do
    assert byte_size(MachineFingerprint.get()) == 32
  end

  test "is stable across calls" do
    assert MachineFingerprint.get() == MachineFingerprint.get()
  end

  test "is lowercase hex" do
    assert MachineFingerprint.get() =~ ~r/^[0-9a-f]{32}$/
  end

  test "does not expose the endpoint secret key base hash" do
    secret_key_fingerprint =
      ZaqWeb.Endpoint.config(:secret_key_base)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    refute MachineFingerprint.get() == secret_key_fingerprint
  end

  test "falls back to a persisted install id when no machine id command is available" do
    with_isolated_install_id(fn path ->
      assert MachineFingerprint.get() =~ ~r/^[0-9a-f]{32}$/
      assert {:ok, install_id} = File.read(path)
      assert install_id =~ ~r/^[0-9a-f-]{36}$/
    end)
  end

  test "reuses an existing persisted install id" do
    with_isolated_install_id(fn path ->
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "  1F3E1D9A-3428-4896-9D01-73EC03D8267A  \n")

      first = MachineFingerprint.get()
      second = MachineFingerprint.get()

      assert first == second
      assert File.read!(path) == "  1F3E1D9A-3428-4896-9D01-73EC03D8267A  \n"
    end)
  end

  test "regenerates the install id when the persisted value is blank" do
    with_isolated_install_id(fn path ->
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, " \n")

      assert MachineFingerprint.get() =~ ~r/^[0-9a-f]{32}$/
      assert File.read!(path) =~ ~r/^[0-9a-f-]{36}$/
    end)
  end

  test "falls back to install id when the macOS machine id command exits non-zero" do
    with_isolated_install_id(fn path ->
      bin_dir = System.get_env("PATH")
      File.mkdir_p!(bin_dir)

      ioreg_path = Path.join(bin_dir, "ioreg")
      File.write!(ioreg_path, "#!/bin/sh\necho unavailable\nexit 1\n")
      File.chmod!(ioreg_path, 0o755)

      assert MachineFingerprint.get() =~ ~r/^[0-9a-f]{32}$/
      assert File.exists?(path)
    end)
  end

  test "uses the first available Linux machine id file" do
    with_isolated_install_id(fn path ->
      File.mkdir_p!(Path.dirname(path))

      first_path = Path.join(Path.dirname(path), "missing-machine-id")
      second_path = Path.join(Path.dirname(path), "machine-id")
      File.write!(second_path, "  ABCDEF123456  \n")

      Application.put_env(:zaq, Zaq.System.MachineFingerprint,
        machine_id_paths: [first_path, second_path],
        product_uuid_path: Path.join(Path.dirname(path), "product-uuid")
      )

      if :os.type() == {:unix, :linux} do
        assert MachineFingerprint.get() == fingerprint(:linux_machine_id, "abcdef123456")
        refute File.exists?(path)
      else
        assert MachineFingerprint.get() =~ ~r/^[0-9a-f]{32}$/
      end
    end)
  end

  test "uses the Linux product UUID when machine id files are blank or missing" do
    with_isolated_install_id(fn path ->
      File.mkdir_p!(Path.dirname(path))

      machine_id_path = Path.join(Path.dirname(path), "blank-machine-id")
      product_uuid_path = Path.join(Path.dirname(path), "product-uuid")
      File.write!(machine_id_path, " \n")
      File.write!(product_uuid_path, "  PRODUCT-UUID-123  \n")

      Application.put_env(:zaq, Zaq.System.MachineFingerprint,
        machine_id_paths: [machine_id_path],
        product_uuid_path: product_uuid_path
      )

      if :os.type() == {:unix, :linux} do
        assert MachineFingerprint.get() == fingerprint(:linux_product_uuid, "product-uuid-123")
        refute File.exists?(path)
      else
        assert MachineFingerprint.get() =~ ~r/^[0-9a-f]{32}$/
      end
    end)
  end

  test "uses the macOS platform UUID command output when available" do
    with_isolated_install_id(fn _path ->
      bin_dir = System.get_env("PATH")
      File.mkdir_p!(bin_dir)

      ioreg_path = Path.join(bin_dir, "ioreg")

      File.write!(
        ioreg_path,
        ~s|#!/bin/sh\necho '    "IOPlatformUUID" = "ABCDEF12-3456-7890-ABCD-EF1234567890"'\n|
      )

      File.chmod!(ioreg_path, 0o755)

      assert MachineFingerprint.get() =~ ~r/^[0-9a-f]{32}$/
    end)
  end

  defp with_isolated_install_id(fun) when is_function(fun, 1) do
    previous_home = System.get_env("HOME")
    previous_xdg_data_home = System.get_env("XDG_DATA_HOME")
    previous_path = System.get_env("PATH")

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "zaq-machine-fingerprint-#{System.unique_integer([:positive])}"
      )

    System.put_env("HOME", tmp_dir)
    System.put_env("XDG_DATA_HOME", Path.join(tmp_dir, "xdg-data"))
    System.put_env("PATH", Path.join(tmp_dir, "empty-bin"))

    Application.put_env(:zaq, Zaq.System.MachineFingerprint,
      machine_id_paths: [Path.join(tmp_dir, "no-machine-id")],
      product_uuid_path: Path.join(tmp_dir, "no-product-uuid")
    )

    on_exit(fn ->
      restore_env("HOME", previous_home)
      restore_env("XDG_DATA_HOME", previous_xdg_data_home)
      restore_env("PATH", previous_path)
      Application.delete_env(:zaq, Zaq.System.MachineFingerprint)
      File.rm_rf(tmp_dir)
    end)

    path =
      :filename.basedir(:user_data, "zaq")
      |> to_string()
      |> Path.join("machine_fingerprint_id")

    fun.(path)
  end

  defp fingerprint(source, identifier) do
    :crypto.hash(:sha256, "zaq-machine-fingerprint-v1:#{source}:#{identifier}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
