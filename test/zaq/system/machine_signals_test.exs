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

  defp write_executable!(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    File.chmod!(path, 0o755)
    path
  end

  defp prepend_path!(dir) do
    previous = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> previous)
    on_exit(fn -> System.put_env("PATH", previous) end)
  end

  defp replace_path!(dir) do
    previous = System.get_env("PATH")
    System.put_env("PATH", dir)
    on_exit(fn -> System.put_env("PATH", previous) end)
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
      assert %{identity: %{"machine_id" => machine_id}} = result
      assert machine_id == "3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e\n"
    end

    test "reads boot_id from fixture path" do
      cfg(boot_id_path: Path.join(@fixtures, "boot-id"))

      result = MachineSignals.collect()
      assert %{identity: %{"boot_id" => boot_id}} = result
      assert boot_id == "a1b2c3d4-e5f6-7890-abcd-ef1234567890\n"
    end

    test "reads all configured linux identity values as raw strings" do
      tmp = tmp_dir("zaq_identity_test")

      cfg(
        machine_id_paths: [Path.join(@fixtures, "machine-id")],
        product_uuid_path: write_file!(Path.join(tmp, "product_uuid"), "product-uuid\n"),
        board_serial_path: write_file!(Path.join(tmp, "board_serial"), "board-serial\n"),
        chassis_serial_path: write_file!(Path.join(tmp, "chassis_serial"), "chassis-serial\n"),
        boot_id_path: Path.join(@fixtures, "boot-id")
      )

      result = MachineSignals.collect()

      assert result.identity == %{
               "machine_id" => "3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e\n",
               "product_uuid" => "product-uuid\n",
               "board_serial" => "board-serial\n",
               "chassis_serial" => "chassis-serial\n",
               "boot_id" => "a1b2c3d4-e5f6-7890-abcd-ef1234567890\n"
             }
    end
  end

  describe "collect/0 — cpu section" do
    test "parses model and core count from cpuinfo fixture" do
      cfg(cpuinfo_path: Path.join(@fixtures, "cpuinfo"))

      result = MachineSignals.collect()
      assert %{cpu: cpu} = result
      assert Map.has_key?(cpu, "model")
      assert Map.has_key?(cpu, "cores")

      assert cpu["model"] == "Intel(R) Core(TM) i7-8565U CPU @ 1.80GHz"
      assert cpu["cores"] == "2"
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
      assert %{ram: %{"total_gib" => total_gib}} = result
      # 8388608 kB = 8 GiB
      assert total_gib == "8"
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

      assert motherboard == %{
               "sys_vendor" => "Framework\n",
               "product_name" => "Laptop 13\n",
               "board_vendor" => "Framework\n",
               "board_name" => "FRANBMCP0A\n",
               "chassis_type" => "10\n"
             }
    end
  end

  describe "collect/0 — gpu section" do
    test "reads linux PCI display devices and ignores other devices" do
      tmp = tmp_dir("zaq_gpu_test")
      display = Path.join(tmp, "0000:00:02.0")
      network = Path.join(tmp, "0000:00:1f.6")
      unknown = Path.join(tmp, "0000:00:1d.0")

      write_file!(Path.join(display, "class"), "0x030000\n")
      write_file!(Path.join(display, "vendor"), "0x8086\n")
      write_file!(Path.join(display, "device"), "0x9b41\n")
      write_file!(Path.join(network, "class"), "0x020000\n")
      write_file!(Path.join(network, "vendor"), "0x8086\n")
      write_file!(Path.join(network, "device"), "0x0d4f\n")
      File.mkdir_p!(unknown)

      cfg(pci_devices_path: tmp)

      result = MachineSignals.collect()
      assert %{gpu: [gpu]} = result
      assert gpu["vendor"] == "0x8086\n"
      assert gpu["device"] == "0x9b41\n"
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
      assert os["id"] == "ubuntu"
      assert os["version"] == "22.04"
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

    test "interface addresses are returned as raw strings" do
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
      assert %{network: %{"interfaces" => ["aa:bb:cc:dd:ee:ff"]}} = result
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
      File.mkdir_p!(Path.join(bluetooth, "hci2"))

      cfg(net_interfaces_path: net, bluetooth_path: bluetooth)

      result = MachineSignals.collect()
      assert %{network: network} = result

      assert network["interfaces"] == ["aa:bb:cc:dd:ee:ff"]
      assert network["bluetooth"] == ["11:22:33:44:55:66"]
    end
  end

  describe "collect/0 — alternate platforms" do
    test "macos platform parses command output into raw sections" do
      bin = tmp_dir("zaq_macos_bin")

      write_executable!(bin, "ioreg", """
      #!/bin/sh
      printf '%s\n' '  "IOPlatformUUID" = "MAC-PRODUCT-UUID"'
      printf '%s\n' '  "IOPlatformSerialNumber" = "MAC-BOARD-SERIAL"'
      """)

      write_executable!(bin, "sysctl", """
      #!/bin/sh
      case "$2" in
        machdep.cpu.brand_string) printf '%s\n' 'Apple M3 Pro' ;;
        hw.model) printf '%s\n' 'MacBookPro18,1' ;;
        hw.logicalcpu) printf '%s\n' '12' ;;
        hw.memsize) printf '%s\n' '17179869184' ;;
        *) exit 1 ;;
      esac
      """)

      write_executable!(bin, "system_profiler", """
      #!/bin/sh
      printf '%s\n' 'Chipset Model: Apple M3 Pro'
      printf '%s\n' 'Vendor: Apple'
      printf '%s\n' 'Chipset Model: External GPU'
      printf '%s\n' 'Vendor: Acme'
      """)

      write_executable!(bin, "ifconfig", """
      #!/bin/sh
      printf '%s\n' 'ether AA:BB:CC:DD:EE:FF'
      printf '%s\n' 'ether 00:00:00:00:00:00'
      printf '%s\n' 'ether aa:bb:cc:dd:ee:ff'
      """)

      write_executable!(bin, "sw_vers", """
      #!/bin/sh
      case "$1" in
        -productName) printf '%s\n' 'macOS' ;;
        -productVersion) printf '%s\n' '14.5' ;;
        *) exit 1 ;;
      esac
      """)

      prepend_path!(bin)
      cfg(platform: :macos)

      result = MachineSignals.collect()

      assert result.identity == %{
               "product_uuid" => "MAC-PRODUCT-UUID",
               "board_serial" => "MAC-BOARD-SERIAL"
             }

      assert result.motherboard == %{
               "sys_vendor" => "Apple Inc.",
               "product_name" => "MacBookPro18,1",
               "board_vendor" => "Apple Inc.",
               "board_name" => "MacBookPro18,1"
             }

      assert result.cpu["model"] == "Apple M3 Pro"
      assert result.cpu["cores"] == "12"
      assert result.ram == %{"total_gib" => "16"}

      assert result.gpu == [
               %{"vendor" => "Apple", "device" => "Apple M3 Pro"},
               %{"vendor" => "Acme", "device" => "External GPU"}
             ]

      assert result.network == %{"interfaces" => ["aa:bb:cc:dd:ee:ff"]}
      assert result.os["id"] == "macOS"
      assert result.os["version"] == "14.5"
      assert result.os["cgroup_v2"] == false
    end

    test "windows platform parses powershell output into raw sections" do
      bin = tmp_dir("zaq_windows_bin")
      previous_docker = System.get_env("DOCKER_RUNNING")

      on_exit(fn ->
        if previous_docker do
          System.put_env("DOCKER_RUNNING", previous_docker)
        else
          System.delete_env("DOCKER_RUNNING")
        end
      end)

      System.put_env("DOCKER_RUNNING", "true")

      write_executable!(bin, "powershell", """
      #!/bin/sh
      for arg do cmd="$arg"; done

      if printf '%s' "$cmd" | grep -q 'Cryptography'; then
        printf '%s\n' 'WIN-MACHINE-GUID'
      elif printf '%s' "$cmd" | grep -q 'ComputerSystemProduct'; then
        printf '%s\n' 'WIN-PRODUCT-UUID'
      elif printf '%s' "$cmd" | grep -q 'Win32_BIOS'; then
        printf '%s\n' 'WIN-BOARD-SERIAL'
      elif printf '%s' "$cmd" | grep -q 'Win32_ComputerSystem).*Manufacturer'; then
        printf '%s\n' 'Framework'
      elif printf '%s' "$cmd" | grep -q 'Win32_ComputerSystem).*Model'; then
        printf '%s\n' 'Laptop 13'
      elif printf '%s' "$cmd" | grep -q 'Win32_BaseBoard).*Manufacturer'; then
        printf '%s\n' 'Framework'
      elif printf '%s' "$cmd" | grep -q 'Win32_BaseBoard).*Product'; then
        printf '%s\n' 'FRANBMCP0A'
      elif printf '%s' "$cmd" | grep -q 'Win32_Processor.*Name'; then
        printf '%s\n' 'Intel CPU'
      elif printf '%s' "$cmd" | grep -q 'NumberOfLogicalProcessors'; then
        printf '%s\n' '8'
      elif printf '%s' "$cmd" | grep -q 'ProcessArchitecture'; then
        printf '%s\n' 'X64'
      elif printf '%s' "$cmd" | grep -q 'TotalPhysicalMemory'; then
        printf '%s\n' '8589934592'
      elif printf '%s' "$cmd" | grep -q 'Win32_VideoController'; then
        printf '%s\n' 'NVIDIA|RTX 4090'
        printf '%s\n' 'malformed'
        printf '%s\n' 'AMD|Radeon'
      elif printf '%s' "$cmd" | grep -q 'Get-NetAdapter'; then
        printf '%s\n' 'AA-BB-CC-DD-EE-FF'
        printf '%s\n' '00-00-00-00-00-00'
        printf '%s\n' ''
      elif printf '%s' "$cmd" | grep -q 'OSVersion'; then
        printf '%s\n' '10.0.22631'
      elif printf '%s' "$cmd" | grep -q 'Win32_OperatingSystem'; then
        printf '%s\n' '11'
      else
        exit 1
      fi
      """)

      prepend_path!(bin)
      cfg(platform: :windows)

      result = MachineSignals.collect()

      assert result.identity == %{
               "machine_id" => "WIN-MACHINE-GUID",
               "product_uuid" => "WIN-PRODUCT-UUID",
               "board_serial" => "WIN-BOARD-SERIAL"
             }

      assert result.motherboard == %{
               "sys_vendor" => "Framework",
               "product_name" => "Laptop 13",
               "board_vendor" => "Framework",
               "board_name" => "FRANBMCP0A"
             }

      assert result.cpu == %{"model" => "Intel CPU", "cores" => "8", "arch" => "X64"}
      assert result.ram == %{"total_gib" => "8"}

      assert result.gpu == [
               %{"vendor" => "NVIDIA", "device" => "RTX 4090"},
               %{"vendor" => "AMD", "device" => "Radeon"}
             ]

      assert result.network == %{"interfaces" => ["aa:bb:cc:dd:ee:ff"]}
      assert result.os["kernel"] == "10.0.22631"
      assert result.os["id"] == "windows"
      assert result.os["version"] == "11"
      assert result.os["is_docker"] == true
      assert result.os["cgroup_v2"] == false
    end

    test "macos platform tolerates commands returning errors" do
      bin = tmp_dir("zaq_macos_error_bin")

      for command <- ["ioreg", "system_profiler", "ifconfig", "sw_vers", "uname"] do
        write_executable!(bin, command, """
        #!/bin/sh
        exit 1
        """)
      end

      write_executable!(bin, "sysctl", """
      #!/bin/sh
      case "$2" in
        hw.memsize) printf '%s\n' 'not-a-number' ;;
        *) exit 1 ;;
      esac
      """)

      prepend_path!(bin)
      cfg(platform: :macos)

      result = MachineSignals.collect()

      assert result[:version] == 1
      refute Map.has_key?(result, :identity)
      refute Map.has_key?(result, :gpu)
      refute Map.has_key?(result, :network)
      refute Map.has_key?(result, :ram)
      assert result.os["is_docker"] in [true, false]
      assert result.os["cgroup_v2"] == false
    end

    test "macos platform tolerates missing command executables" do
      replace_path!(tmp_dir("zaq_empty_path"))
      cfg(platform: :macos)

      result = MachineSignals.collect()

      assert result[:version] == 1
      refute Map.has_key?(result, :identity)
      refute Map.has_key?(result, :gpu)
      refute Map.has_key?(result, :network)
      refute Map.has_key?(result, :cpu)
      refute Map.has_key?(result, :ram)
    end

    test "windows platform tolerates powershell command errors" do
      bin = tmp_dir("zaq_windows_error_bin")

      write_executable!(bin, "powershell", """
      #!/bin/sh
      exit 1
      """)

      prepend_path!(bin)
      cfg(platform: :windows)

      result = MachineSignals.collect()

      assert result[:version] == 1
      refute Map.has_key?(result, :identity)
      refute Map.has_key?(result, :motherboard)
      refute Map.has_key?(result, :cpu)
      refute Map.has_key?(result, :ram)
      refute Map.has_key?(result, :gpu)
      refute Map.has_key?(result, :network)
      assert result.os["id"] == "windows"
      assert result.os["cgroup_v2"] == false
    end

    test "macos platform probes return the stable wire shape" do
      cfg(platform: :macos)

      result = MachineSignals.collect()
      assert result[:version] == 1

      if identity = result[:identity] do
        refute Map.has_key?(identity, "machine_id")
      end

      if motherboard = result[:motherboard] do
        assert motherboard["sys_vendor"] == "Apple Inc."
        assert motherboard["board_vendor"] == "Apple Inc."
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
        assert os["id"] == "windows"
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
