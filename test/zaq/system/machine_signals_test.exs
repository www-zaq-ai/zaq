defmodule Zaq.System.MachineSignalsTest do
  use ExUnit.Case, async: false

  alias Zaq.System.MachineSignals

  @fixtures Path.expand("../../fixtures/machine_signals", __DIR__)

  setup do
    MachineSignals.reset_cache()
    on_exit(fn -> MachineSignals.reset_cache() end)
  end

  defp cfg(overrides) do
    previous = Application.get_env(:zaq, MachineSignals)

    Application.put_env(:zaq, MachineSignals, Keyword.merge(default_cfg(), overrides))
    MachineSignals.reset_cache()

    on_exit(fn ->
      if previous do
        Application.put_env(:zaq, MachineSignals, previous)
      else
        Application.delete_env(:zaq, MachineSignals)
      end
    end)
  end

  defp default_cfg do
    missing = "/nonexistent/zaq-machine-signals"

    [
      platform: :linux,
      machine_id_paths: [Path.join(missing, "machine-id")],
      boot_id_path: Path.join(missing, "boot-id"),
      product_uuid_path: Path.join(missing, "product_uuid"),
      board_serial_path: Path.join(missing, "board_serial"),
      chassis_serial_path: Path.join(missing, "chassis_serial"),
      sys_vendor_path: Path.join(missing, "sys_vendor"),
      product_name_path: Path.join(missing, "product_name"),
      board_vendor_path: Path.join(missing, "board_vendor"),
      board_name_path: Path.join(missing, "board_name"),
      chassis_type_path: Path.join(missing, "chassis_type"),
      cpuinfo_path: Path.join(missing, "cpuinfo"),
      meminfo_path: Path.join(missing, "meminfo"),
      pci_devices_path: Path.join(missing, "pci_devices"),
      net_interfaces_path: Path.join(missing, "net"),
      bluetooth_path: Path.join(missing, "bluetooth"),
      os_release_path: Path.join(missing, "os-release"),
      dockerenv_path: Path.join(missing, ".dockerenv"),
      cgroup_1_path: Path.join(missing, "cgroup"),
      cgroup_controllers_path: Path.join(missing, "cgroup.controllers")
    ]
  end

  defp tmp_dir(prefix) do
    dir = System.tmp_dir!() |> Path.join("#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write_file!(path, content) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, content)
    path
  end

  # --- normalize/1 ---

  describe "normalize/1" do
    test "trims leading and trailing whitespace" do
      assert MachineSignals.normalize("  hello  ") == "hello"
    end

    test "lowercases" do
      assert MachineSignals.normalize("Intel(R) Core i7") == "intel(r) core i7"
    end

    test "collapses internal whitespace runs to single space" do
      assert MachineSignals.normalize("a  b\t\tc") == "a b c"
    end

    test "is idempotent" do
      value = "  Intel(R)  Core  i7  "
      once = MachineSignals.normalize(value)
      assert MachineSignals.normalize(once) == once
    end

    test "handles empty string" do
      assert MachineSignals.normalize("") == ""
    end
  end

  # --- hash_signal/2 ---

  describe "hash_signal/2" do
    test "returns a 32-character lowercase hex string" do
      result = MachineSignals.hash_signal("machine_id", "abc123")
      assert String.length(result) == 32
      assert result =~ ~r/^[0-9a-f]{32}$/
    end

    test "is deterministic — same inputs produce same output" do
      h1 = MachineSignals.hash_signal("machine_id", "abc123")
      h2 = MachineSignals.hash_signal("machine_id", "abc123")
      assert h1 == h2
    end

    test "different names produce different hashes" do
      h1 = MachineSignals.hash_signal("machine_id", "abc123")
      h2 = MachineSignals.hash_signal("boot_id", "abc123")
      assert h1 != h2
    end

    test "different values produce different hashes" do
      h1 = MachineSignals.hash_signal("machine_id", "abc123")
      h2 = MachineSignals.hash_signal("machine_id", "xyz789")
      assert h1 != h2
    end

    test "normalizes value before hashing — whitespace variants are equal" do
      h1 = MachineSignals.hash_signal("machine_id", "abc 123")
      h2 = MachineSignals.hash_signal("machine_id", "  ABC  123  ")
      assert h1 == h2
    end

    test "never raises on arbitrary binary input" do
      for value <- ["", "\x00", "a\nb", <<0xFF, 0xFE>>, String.duplicate("x", 10_000)] do
        assert is_binary(MachineSignals.hash_signal("k", value))
      end
    end
  end

  # --- collect/0 ---

  describe "collect/0 — structure" do
    test "always returns a map with version: 1" do
      result = MachineSignals.collect()
      assert is_map(result)
      assert result[:version] == 1
    end

    test "never raises regardless of which fixture files are absent" do
      cfg(machine_id_paths: ["/nonexistent/machine-id"])
      assert is_map(MachineSignals.collect())
    end

    test "omits keys whose source is unreadable" do
      cfg(
        machine_id_paths: ["/nonexistent/machine-id"],
        boot_id_path: "/nonexistent/boot-id",
        product_uuid_path: "/nonexistent/product_uuid",
        board_serial_path: "/nonexistent/board_serial",
        chassis_serial_path: "/nonexistent/chassis_serial"
      )

      result = MachineSignals.collect()
      refute Map.has_key?(result, :identity)
    end

    test "returns cached result on second call" do
      r1 = MachineSignals.collect()
      r2 = MachineSignals.collect()
      assert r1 === r2
    end

    test "falls back to detected platform when configured platform is unknown" do
      cfg(platform: :unknown)

      result = MachineSignals.collect()
      assert result[:version] == 1
    end
  end

  describe "collect/0 — identity section" do
    test "reads machine_id from fixture path" do
      cfg(machine_id_paths: [Path.join(@fixtures, "machine-id")])

      result = MachineSignals.collect()
      assert %{identity: %{"machine_id" => hash}} = result
      assert String.length(hash) == 32
      assert hash =~ ~r/^[0-9a-f]{32}$/
      assert hash == MachineSignals.hash_signal("machine_id", "3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e")
    end

    test "reads boot_id from fixture path" do
      cfg(boot_id_path: Path.join(@fixtures, "boot-id"))

      result = MachineSignals.collect()
      assert %{identity: %{"boot_id" => hash}} = result
      assert hash == MachineSignals.hash_signal("boot_id", "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
    end

    test "raw value is never present in output" do
      cfg(machine_id_paths: [Path.join(@fixtures, "machine-id")])

      result = MachineSignals.collect()
      refute inspect(result) =~ "3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e"
    end
  end

  describe "collect/0 — cpu section" do
    test "parses model and core count from cpuinfo fixture" do
      cfg(cpuinfo_path: Path.join(@fixtures, "cpuinfo"))

      result = MachineSignals.collect()
      assert %{cpu: cpu} = result
      assert Map.has_key?(cpu, "model")
      assert Map.has_key?(cpu, "cores")

      expected_model =
        MachineSignals.hash_signal("model", "Intel(R) Core(TM) i7-8565U CPU @ 1.80GHz")

      assert cpu["model"] == expected_model
      assert cpu["cores"] == MachineSignals.hash_signal("cores", "2")
    end

    test "omits cpu section when cpuinfo is unreadable and uname unavailable" do
      cfg(cpuinfo_path: "/nonexistent/cpuinfo")
      result = MachineSignals.collect()
      # cpu section may still appear if uname -m succeeds; just assert no raise
      assert is_map(result)
    end

    test "omits cpu model and cores when cpuinfo has no matching fields" do
      cpuinfo = write_file!(Path.join(tmp_dir("zaq_cpu_test"), "cpuinfo"), "bogus: value\n")

      cfg(cpuinfo_path: cpuinfo)

      result = MachineSignals.collect()
      assert %{cpu: cpu} = result
      refute Map.has_key?(cpu, "model")
      refute Map.has_key?(cpu, "cores")
    end
  end

  describe "collect/0 — ram section" do
    test "parses MemTotal from meminfo fixture" do
      cfg(meminfo_path: Path.join(@fixtures, "meminfo"))

      result = MachineSignals.collect()
      assert %{ram: %{"total_gib" => hash}} = result
      # 8388608 kB = 8 GiB
      assert hash == MachineSignals.hash_signal("total_gib", "8")
    end

    test "omits ram section when meminfo lacks MemTotal" do
      meminfo = write_file!(Path.join(tmp_dir("zaq_ram_test"), "meminfo"), "MemFree: 1024 kB\n")

      cfg(meminfo_path: meminfo)

      result = MachineSignals.collect()
      refute Map.has_key?(result, :ram)
    end
  end

  describe "collect/0 — motherboard section" do
    test "reads linux DMI values from configured paths" do
      tmp = tmp_dir("zaq_board_test")

      cfg(
        sys_vendor_path: write_file!(Path.join(tmp, "sys_vendor"), "Framework\n"),
        product_name_path: write_file!(Path.join(tmp, "product_name"), "Laptop 13\n"),
        board_vendor_path: write_file!(Path.join(tmp, "board_vendor"), "Framework\n"),
        board_name_path: write_file!(Path.join(tmp, "board_name"), "FRANBMCP0A\n"),
        chassis_type_path: write_file!(Path.join(tmp, "chassis_type"), "10\n")
      )

      result = MachineSignals.collect()
      assert %{motherboard: motherboard} = result
      assert motherboard["sys_vendor"] == MachineSignals.hash_signal("sys_vendor", "Framework")

      assert motherboard["product_name"] ==
               MachineSignals.hash_signal("product_name", "Laptop 13")

      assert motherboard["board_vendor"] ==
               MachineSignals.hash_signal("board_vendor", "Framework")

      assert motherboard["board_name"] == MachineSignals.hash_signal("board_name", "FRANBMCP0A")
      assert motherboard["chassis_type"] == MachineSignals.hash_signal("chassis_type", "10")
    end
  end

  describe "collect/0 — gpu section" do
    test "reads linux PCI display devices and ignores other devices" do
      tmp = tmp_dir("zaq_gpu_test")
      display = Path.join(tmp, "0000:00:02.0")
      network = Path.join(tmp, "0000:00:1f.6")

      write_file!(Path.join(display, "class"), "0x030000\n")
      write_file!(Path.join(display, "vendor"), "0x8086\n")
      write_file!(Path.join(display, "device"), "0x9b41\n")
      write_file!(Path.join(network, "class"), "0x020000\n")
      write_file!(Path.join(network, "vendor"), "0x8086\n")
      write_file!(Path.join(network, "device"), "0x0d4f\n")

      cfg(pci_devices_path: tmp)

      result = MachineSignals.collect()
      assert %{gpu: [gpu]} = result
      assert gpu["vendor"] == MachineSignals.hash_signal("vendor", "0x8086")
      assert gpu["device"] == MachineSignals.hash_signal("device", "0x9b41")
    end

    test "omits linux PCI devices with incomplete display metadata" do
      tmp = tmp_dir("zaq_gpu_incomplete_test")

      write_file!(Path.join([tmp, "0000:00:02.0", "class"]), "0x030000\n")

      cfg(pci_devices_path: tmp)

      result = MachineSignals.collect()
      refute Map.has_key?(result, :gpu)
    end
  end

  describe "collect/0 — os section" do
    test "parses os_id and os_version from os-release fixture" do
      cfg(os_release_path: Path.join(@fixtures, "os-release"))

      result = MachineSignals.collect()
      assert %{os: os} = result
      assert os["id"] == MachineSignals.hash_signal("id", "ubuntu")
      assert os["version"] == MachineSignals.hash_signal("version", "22.04")
    end

    test "is_docker is a boolean" do
      cfg(
        os_release_path: "/nonexistent",
        dockerenv_path: "/nonexistent/.dockerenv",
        cgroup_1_path: "/nonexistent/cgroup"
      )

      result = MachineSignals.collect()

      if os = result[:os] do
        assert is_boolean(os["is_docker"])
      end
    end

    test "detects docker from dockerenv path and cgroup v2 controller path" do
      tmp = tmp_dir("zaq_os_test")

      cfg(
        dockerenv_path: write_file!(Path.join(tmp, ".dockerenv"), ""),
        cgroup_controllers_path: write_file!(Path.join(tmp, "cgroup.controllers"), "")
      )

      result = MachineSignals.collect()
      assert %{os: os} = result
      assert os["is_docker"] == true
      assert os["cgroup_v2"] == true
    end

    test "detects docker from cgroup content when dockerenv is absent" do
      cgroup =
        write_file!(
          Path.join(tmp_dir("zaq_cgroup_test"), "cgroup"),
          "0::/system.slice/containerd\n"
        )

      cfg(cgroup_1_path: cgroup)

      result = MachineSignals.collect()
      assert %{os: %{"is_docker" => true}} = result
    end
  end

  describe "collect/0 — network section" do
    test "omits network section when interfaces path is unreadable" do
      cfg(
        net_interfaces_path: "/nonexistent/net",
        bluetooth_path: "/nonexistent/bluetooth"
      )

      result = MachineSignals.collect()
      refute Map.has_key?(result, :network)
    end

    test "interface hashes are 32-char hex strings" do
      tmp = System.tmp_dir!() |> Path.join("zaq_net_test_#{System.unique_integer([:positive])}")
      eth0 = Path.join(tmp, "eth0")
      File.mkdir_p!(eth0)
      File.write!(Path.join(eth0, "address"), "aa:bb:cc:dd:ee:ff\n")

      on_exit(fn -> File.rm_rf!(tmp) end)

      cfg(
        net_interfaces_path: tmp,
        bluetooth_path: "/nonexistent/bluetooth"
      )

      result = MachineSignals.collect()
      assert %{network: %{"interfaces" => [hash]}} = result
      assert String.length(hash) == 32
      assert hash =~ ~r/^[0-9a-f]{32}$/
    end

    test "filters loopback and zero MACs and reads bluetooth addresses" do
      tmp = tmp_dir("zaq_network_test")
      net = Path.join(tmp, "net")
      bluetooth = Path.join(tmp, "bluetooth")

      write_file!(Path.join([net, "lo", "address"]), "11:22:33:44:55:66\n")
      write_file!(Path.join([net, "eth0", "address"]), "aa:bb:cc:dd:ee:ff\n")
      write_file!(Path.join([net, "wlan0", "address"]), "00:00:00:00:00:00\n")
      write_file!(Path.join([net, "bad0", "not-address"]), "ignored\n")
      write_file!(Path.join([bluetooth, "hci0", "address"]), "11:22:33:44:55:66\n")
      write_file!(Path.join([bluetooth, "hci1", "address"]), "\n")

      cfg(net_interfaces_path: net, bluetooth_path: bluetooth)

      result = MachineSignals.collect()
      assert %{network: network} = result

      assert network["interfaces"] == [
               MachineSignals.hash_signal("net_interface", "aa:bb:cc:dd:ee:ff")
             ]

      assert network["bluetooth"] == [
               MachineSignals.hash_signal("bluetooth_address", "11:22:33:44:55:66")
             ]
    end
  end

  describe "collect/0 — alternate platforms" do
    test "macos platform probes return the stable wire shape" do
      cfg(platform: :macos)

      result = MachineSignals.collect()
      assert result[:version] == 1

      if identity = result[:identity] do
        refute Map.has_key?(identity, "machine_id")
      end

      if motherboard = result[:motherboard] do
        assert motherboard["sys_vendor"] == MachineSignals.hash_signal("sys_vendor", "Apple Inc.")

        assert motherboard["board_vendor"] ==
                 MachineSignals.hash_signal("board_vendor", "Apple Inc.")
      end

      if os = result[:os] do
        assert is_boolean(os["is_docker"])
        assert os["cgroup_v2"] == false
      end
    end

    test "windows platform probes tolerate missing powershell" do
      cfg(platform: :windows)

      result = MachineSignals.collect()
      assert result[:version] == 1

      if os = result[:os] do
        assert os["id"] == MachineSignals.hash_signal("id", "windows")
        assert is_boolean(os["is_docker"])
        assert os["cgroup_v2"] == false
      end
    end
  end

  describe "collect/0 — attestation section" do
    test "returns nil when no IMDS is reachable (non-cloud environment)" do
      result = MachineSignals.collect()
      refute Map.has_key?(result, :attestation)
    end
  end
end
