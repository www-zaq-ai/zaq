defmodule Zaq.System.MachineSignals do
  @moduledoc false

  @hash_prefix "zaq-signal-v1:"
  @hash_length 32
  @cache_key {__MODULE__, :signals}
  @imds_timeout_ms 500

  @doc """
  Returns the machine signals map with all available signals, hashed per the
  wire format. Memoized in `:persistent_term` — probes run once per boot.
  """
  @spec collect() :: map()
  def collect do
    case :persistent_term.get(@cache_key, nil) do
      nil ->
        signals = build()
        :persistent_term.put(@cache_key, signals)
        signals

      cached ->
        cached
    end
  end

  @doc false
  def reset_cache, do: :persistent_term.erase(@cache_key)

  @doc """
  Normalizes a raw signal value: trims whitespace, lowercases, collapses
  internal whitespace runs to a single space.

  Exported for shared test-vector verification with the Portal — both sides
  must produce byte-identical output.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
  end

  @doc """
  Hashes a single signal. Wire format:
  `sha256("zaq-signal-v1:" <> name <> ":" <> normalize(value))` → first 32 hex chars.
  """
  @spec hash_signal(String.t(), String.t()) :: String.t()
  def hash_signal(name, value) when is_binary(name) and is_binary(value) do
    (@hash_prefix <> name <> ":" <> normalize(value))
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, @hash_length)
  end

  # --- private builders ---

  defp build do
    [
      {:identity, identity()},
      {:motherboard, motherboard()},
      {:cpu, cpu()},
      {:ram, ram()},
      {:gpu, gpu()},
      {:network, network()},
      {:os, os_info()},
      {:attestation, attestation()}
    ]
    |> Enum.reduce(%{version: 1}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp platform do
    case Keyword.get(cfg(), :platform) do
      platform when platform in [:linux, :macos, :windows] ->
        platform

      _ ->
        case :os.type() do
          {:unix, :darwin} -> :macos
          {:win32, _} -> :windows
          _ -> :linux
        end
    end
  end

  # --- identity ---

  defp identity do
    case platform() do
      :linux -> identity_linux()
      :macos -> identity_macos()
      :windows -> identity_windows()
    end
  end

  defp identity_linux do
    cfg = cfg()

    section([
      {"machine_id",
       read_first_file(
         Keyword.get(cfg, :machine_id_paths, ["/etc/machine-id", "/var/lib/dbus/machine-id"])
       )},
      {"product_uuid",
       read_file(Keyword.get(cfg, :product_uuid_path, "/sys/class/dmi/id/product_uuid"))},
      {"board_serial",
       read_file(Keyword.get(cfg, :board_serial_path, "/sys/class/dmi/id/board_serial"))},
      {"chassis_serial",
       read_file(Keyword.get(cfg, :chassis_serial_path, "/sys/class/dmi/id/chassis_serial"))},
      {"boot_id", read_file(Keyword.get(cfg, :boot_id_path, "/proc/sys/kernel/random/boot_id"))}
    ])
  end

  defp identity_macos do
    ioreg = ioreg_platform_expert()

    section([
      {"product_uuid", ioreg_extract(ioreg, "IOPlatformUUID")},
      {"board_serial", ioreg_extract(ioreg, "IOPlatformSerialNumber")}
    ])
  end

  defp identity_windows do
    section([
      {"machine_id",
       ps_value("(Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Cryptography').MachineGuid")},
      {"product_uuid", ps_value("(Get-WmiObject Win32_ComputerSystemProduct).UUID")},
      {"board_serial", ps_value("(Get-WmiObject Win32_BIOS).SerialNumber")}
    ])
  end

  # --- motherboard ---

  defp motherboard do
    case platform() do
      :linux -> motherboard_linux()
      :macos -> motherboard_macos()
      :windows -> motherboard_windows()
    end
  end

  defp motherboard_linux do
    cfg = cfg()

    section([
      {"sys_vendor",
       read_file(Keyword.get(cfg, :sys_vendor_path, "/sys/class/dmi/id/sys_vendor"))},
      {"product_name",
       read_file(Keyword.get(cfg, :product_name_path, "/sys/class/dmi/id/product_name"))},
      {"board_vendor",
       read_file(Keyword.get(cfg, :board_vendor_path, "/sys/class/dmi/id/board_vendor"))},
      {"board_name",
       read_file(Keyword.get(cfg, :board_name_path, "/sys/class/dmi/id/board_name"))},
      {"chassis_type",
       read_file(Keyword.get(cfg, :chassis_type_path, "/sys/class/dmi/id/chassis_type"))}
    ])
  end

  defp motherboard_macos do
    model = sysctl_n("hw.model")

    section([
      {"sys_vendor", "Apple Inc."},
      {"product_name", model},
      {"board_vendor", "Apple Inc."},
      {"board_name", model}
    ])
  end

  defp motherboard_windows do
    section([
      {"sys_vendor", ps_value("(Get-WmiObject Win32_ComputerSystem).Manufacturer")},
      {"product_name", ps_value("(Get-WmiObject Win32_ComputerSystem).Model")},
      {"board_vendor", ps_value("(Get-WmiObject Win32_BaseBoard).Manufacturer")},
      {"board_name", ps_value("(Get-WmiObject Win32_BaseBoard).Product")}
    ])
  end

  # --- cpu ---

  defp cpu do
    case platform() do
      :linux -> cpu_linux()
      :macos -> cpu_macos()
      :windows -> cpu_windows()
    end
  end

  defp cpu_linux do
    cfg = cfg()
    content = read_file(Keyword.get(cfg, :cpuinfo_path, "/proc/cpuinfo"))

    section([
      {"model", cpuinfo_model(content)},
      {"cores", cpuinfo_count(content) |> int_str()},
      {"arch", uname("-m")}
    ])
  end

  defp cpu_macos do
    # machdep.cpu.brand_string is Intel-only; fall back to hw.model for Apple Silicon
    model = sysctl_n("machdep.cpu.brand_string") || sysctl_n("hw.model")

    section([
      {"model", model},
      {"cores", sysctl_n("hw.logicalcpu")},
      {"arch", uname("-m")}
    ])
  end

  defp cpu_windows do
    section([
      {"model", ps_value("(Get-WmiObject Win32_Processor | Select-Object -First 1).Name")},
      {"cores",
       ps_value(
         "(Get-WmiObject Win32_Processor | Select-Object -First 1).NumberOfLogicalProcessors"
       )},
      {"arch",
       ps_value(
         "[System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()"
       )}
    ])
  end

  # --- ram ---

  defp ram do
    case platform() do
      :linux -> ram_linux()
      :macos -> ram_macos()
      :windows -> ram_windows()
    end
  end

  defp ram_linux do
    cfg = cfg()
    content = read_file(Keyword.get(cfg, :meminfo_path, "/proc/meminfo"))

    section([{"total_gib", mem_total_gib(content) |> int_str()}])
  end

  defp ram_macos do
    gib =
      case sysctl_n("hw.memsize") do
        nil -> nil
        bytes_str -> parse_bytes_to_gib(bytes_str)
      end

    section([{"total_gib", int_str(gib)}])
  end

  defp ram_windows do
    gib =
      case ps_value("(Get-WmiObject Win32_ComputerSystem).TotalPhysicalMemory") do
        nil -> nil
        bytes_str -> parse_bytes_to_gib(bytes_str)
      end

    section([{"total_gib", int_str(gib)}])
  end

  defp parse_bytes_to_gib(bytes_str) do
    case Integer.parse(bytes_str) do
      {bytes, _} -> div(bytes, 1_073_741_824)
      _ -> nil
    end
  end

  # --- gpu ---

  defp gpu do
    case platform() do
      :linux -> gpu_linux()
      :macos -> gpu_macos()
      :windows -> gpu_windows()
    end
  end

  defp gpu_linux do
    cfg = cfg()
    pci_base = Keyword.get(cfg, :pci_devices_path, "/sys/bus/pci/devices")

    devs =
      pci_base
      |> File.ls!()
      |> Enum.filter(fn dev ->
        case File.read(Path.join([pci_base, dev, "class"])) do
          {:ok, cls} -> String.starts_with?(String.trim(cls), "0x03")
          _ -> false
        end
      end)
      |> Enum.map(fn dev ->
        section([
          {"vendor", read_file(Path.join([pci_base, dev, "vendor"]))},
          {"device", read_file(Path.join([pci_base, dev, "device"]))}
        ])
      end)
      |> Enum.reject(&is_nil/1)

    if devs == [], do: nil, else: devs
  rescue
    File.Error -> nil
  end

  defp gpu_macos do
    case System.cmd("system_profiler", ["SPDisplaysDataType"], stderr_to_stdout: false) do
      {output, 0} -> parse_macos_gpus(output)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp parse_macos_gpus(output) do
    # system_profiler lists "Chipset Model:" then "Vendor:" for each GPU in order
    models =
      Regex.scan(~r/Chipset Model:\s*(.+)/, output)
      |> Enum.map(fn [_, m] -> String.trim(m) end)

    vendors =
      Regex.scan(~r/Vendor:\s*(.+)/, output)
      |> Enum.map(fn [_, v] -> String.trim(v) end)

    devs =
      Enum.zip(vendors, models)
      |> Enum.map(fn {vendor, device} ->
        section([{"vendor", vendor}, {"device", device}])
      end)
      |> Enum.reject(&is_nil/1)

    if devs == [], do: nil, else: devs
  end

  defp gpu_windows do
    script =
      "Get-WmiObject Win32_VideoController | ForEach-Object { $_.AdapterCompatibility + '|' + $_.Name }"

    case ps_lines(script) do
      nil ->
        nil

      lines ->
        devs =
          lines
          |> Enum.map(&windows_gpu_device/1)
          |> Enum.reject(&is_nil/1)

        if devs == [], do: nil, else: devs
    end
  end

  defp windows_gpu_device(line) do
    case String.split(line, "|", parts: 2) do
      [vendor, device] -> section([{"vendor", vendor}, {"device", device}])
      _ -> nil
    end
  end

  # --- network ---

  defp network do
    case platform() do
      :linux -> network_linux()
      :macos -> network_macos()
      :windows -> network_windows()
    end
  end

  defp network_linux do
    cfg = cfg()
    net_base = Keyword.get(cfg, :net_interfaces_path, "/sys/class/net")
    bt_base = Keyword.get(cfg, :bluetooth_path, "/sys/class/bluetooth")

    iface_hashes =
      case net_iface_macs(net_base) do
        nil -> nil
        macs -> Enum.map(macs, &hash_signal("net_interface", &1))
      end

    bt_hashes =
      case bt_addresses(bt_base) do
        nil -> nil
        addrs -> Enum.map(addrs, &hash_signal("bluetooth_address", &1))
      end

    section([
      {"interfaces", iface_hashes && {:raw, iface_hashes}},
      {"bluetooth", bt_hashes && {:raw, bt_hashes}}
    ])
  end

  defp network_macos do
    macs = macos_iface_macs()
    iface_hashes = macs && Enum.map(macs, &hash_signal("net_interface", &1))

    section([{"interfaces", iface_hashes && {:raw, iface_hashes}}])
  end

  defp macos_iface_macs do
    case System.cmd("ifconfig", [], stderr_to_stdout: false) do
      {output, 0} ->
        macs =
          ~r/ether\s+([0-9a-f]{2}(?::[0-9a-f]{2}){5})/i
          |> Regex.scan(output)
          |> Enum.map(fn [_, mac] -> String.downcase(mac) end)
          |> Enum.reject(&(&1 == "00:00:00:00:00:00"))
          |> Enum.uniq()

        if macs == [], do: nil, else: macs

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp network_windows do
    script =
      "Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -ExpandProperty MacAddress"

    case ps_lines(script) do
      nil ->
        nil

      raw_macs ->
        macs =
          raw_macs
          |> Enum.map(&String.downcase(String.replace(&1, "-", ":")))
          |> Enum.reject(&(&1 in ["", "00:00:00:00:00:00"]))

        iface_hashes =
          if macs == [], do: nil, else: Enum.map(macs, &hash_signal("net_interface", &1))

        section([{"interfaces", iface_hashes && {:raw, iface_hashes}}])
    end
  end

  defp net_iface_macs(base) do
    macs =
      base
      |> File.ls!()
      |> Enum.reject(&(&1 == "lo"))
      |> Enum.flat_map(&read_iface_mac(base, &1))

    if macs == [], do: nil, else: macs
  rescue
    File.Error -> nil
  end

  defp read_iface_mac(base, iface) do
    case File.read(Path.join([base, iface, "address"])) do
      {:ok, mac} ->
        mac = String.trim(mac)
        if mac in ["", "00:00:00:00:00:00"], do: [], else: [mac]

      _ ->
        []
    end
  end

  defp bt_addresses(base) do
    addrs =
      base
      |> File.ls!()
      |> Enum.flat_map(&read_bt_address(base, &1))

    if addrs == [], do: nil, else: addrs
  rescue
    File.Error -> nil
  end

  defp read_bt_address(base, adapter) do
    case File.read(Path.join([base, adapter, "address"])) do
      {:ok, addr} ->
        addr = String.trim(addr)
        if addr == "", do: [], else: [addr]

      _ ->
        []
    end
  end

  # --- os_info ---

  defp os_info do
    case platform() do
      :linux -> os_info_linux()
      :macos -> os_info_macos()
      :windows -> os_info_windows()
    end
  end

  defp os_info_linux do
    cfg = cfg()
    os_release = read_file(Keyword.get(cfg, :os_release_path, "/etc/os-release"))
    dockerenv = Keyword.get(cfg, :dockerenv_path, "/.dockerenv")
    cgroup_1 = Keyword.get(cfg, :cgroup_1_path, "/proc/1/cgroup")
    cgroup_ctrl = Keyword.get(cfg, :cgroup_controllers_path, "/sys/fs/cgroup/cgroup.controllers")

    {os_id, os_version} = parse_os_release(os_release)

    section([
      {"kernel", uname("-r")},
      {"id", os_id},
      {"version", os_version},
      {"hostname", read_hostname()},
      {"is_docker", {:raw, docker?(dockerenv, cgroup_1)}},
      {"cgroup_v2", {:raw, File.exists?(cgroup_ctrl)}}
    ])
  end

  defp os_info_macos do
    section([
      {"kernel", uname("-r")},
      {"id", sw_vers("productName")},
      {"version", sw_vers("productVersion")},
      {"hostname", read_hostname()},
      {"is_docker", {:raw, File.exists?("/.dockerenv")}},
      {"cgroup_v2", {:raw, false}}
    ])
  end

  defp os_info_windows do
    section([
      {"kernel", ps_value("[System.Environment]::OSVersion.Version.ToString()")},
      {"id", "windows"},
      {"version", ps_value("(Get-WmiObject Win32_OperatingSystem).Version")},
      {"hostname", read_hostname()},
      {"is_docker", {:raw, windows_in_docker?()}},
      {"cgroup_v2", {:raw, false}}
    ])
  end

  defp windows_in_docker? do
    System.get_env("DOCKER_RUNNING") == "true" or
      File.exists?("C:\\ProgramData\\Docker\\config\\daemon.json")
  end

  # --- attestation ---

  defp attestation do
    tasks = [
      Task.async(fn -> {:aws, fetch_aws()} end),
      Task.async(fn -> {:gcp, fetch_gcp()} end),
      Task.async(fn -> {:azure, fetch_azure()} end)
    ]

    tasks
    |> Task.yield_many(@imds_timeout_ms + 100)
    |> Enum.reduce_while(nil, fn {task, outcome}, _acc ->
      case outcome do
        {:ok, {provider, doc}} when is_binary(doc) ->
          {:halt, %{provider: Atom.to_string(provider), document: doc}}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:cont, nil}

        _ ->
          {:cont, nil}
      end
    end)
  end

  # Placeholders — IMDS calls require HTTP to 169.254.169.254 with 500ms timeout.
  # Implemented once Req is confirmed available in this context or a dedicated
  # HTTP helper is wired in.
  defp fetch_aws, do: nil
  defp fetch_gcp, do: nil
  defp fetch_azure, do: nil

  # --- section builder ---

  defp section(pairs) do
    result =
      Enum.reduce(pairs, %{}, fn
        {_k, nil}, acc -> acc
        {_k, {:raw, nil}}, acc -> acc
        {_k, {:raw, []}}, acc -> acc
        {k, {:raw, v}}, acc -> Map.put(acc, k, v)
        {k, v}, acc when is_binary(v) -> Map.put(acc, k, hash_signal(k, v))
        _, acc -> acc
      end)

    if result == %{}, do: nil, else: result
  end

  # --- file helpers ---

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp read_first_file(paths), do: Enum.find_value(paths, &read_file/1)

  # --- parsers ---

  defp cpuinfo_model(nil), do: nil

  defp cpuinfo_model(content) do
    Enum.find_value(String.split(content, "\n"), fn line ->
      case Regex.run(~r/^model name\s*:\s*(.+)$/, line) do
        [_, model] -> String.trim(model)
        _ -> nil
      end
    end)
  end

  defp cpuinfo_count(nil), do: nil

  defp cpuinfo_count(content) do
    n = Enum.count(String.split(content, "\n"), &String.starts_with?(&1, "processor"))
    if n == 0, do: nil, else: n
  end

  defp mem_total_gib(nil), do: nil

  defp mem_total_gib(content) do
    Enum.find_value(String.split(content, "\n"), fn line ->
      case Regex.run(~r/^MemTotal:\s+(\d+)\s+kB/, line) do
        [_, kb] -> String.to_integer(kb) |> div(1_048_576)
        _ -> nil
      end
    end)
  end

  defp parse_os_release(nil), do: {nil, nil}

  defp parse_os_release(content) do
    lines = String.split(content, "\n")

    id =
      Enum.find_value(lines, fn line ->
        case Regex.run(~r/^ID=(.+)$/, line) do
          [_, v] -> String.trim(v, "\"")
          _ -> nil
        end
      end)

    version =
      Enum.find_value(lines, fn line ->
        case Regex.run(~r/^VERSION_ID=(.+)$/, line) do
          [_, v] -> String.trim(v, "\"")
          _ -> nil
        end
      end)

    {id, version}
  end

  defp docker?(dockerenv_path, cgroup_1_path) do
    if File.exists?(dockerenv_path) do
      true
    else
      case File.read(cgroup_1_path) do
        {:ok, content} -> String.contains?(content, ["docker", "containerd"])
        _ -> false
      end
    end
  end

  defp read_hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> nil
    end
  end

  defp uname(flag) do
    case System.cmd("uname", [flag], stderr_to_stdout: false) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp int_str(nil), do: nil
  defp int_str(n), do: Integer.to_string(n)

  # --- macOS helpers ---

  defp ioreg_platform_expert do
    case System.cmd("ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"], stderr_to_stdout: false) do
      {output, 0} -> output
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp ioreg_extract(nil, _key), do: nil

  defp ioreg_extract(output, key) do
    case Regex.run(~r/"#{Regex.escape(key)}"\s*=\s*"([^"]+)"/, output) do
      [_, v] -> String.trim(v)
      _ -> nil
    end
  end

  defp sysctl_n(key) do
    case System.cmd("sysctl", ["-n", key], stderr_to_stdout: false) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp sw_vers(field) do
    case System.cmd("sw_vers", ["-#{field}"], stderr_to_stdout: false) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # --- Windows helpers ---

  defp ps_value(script) do
    case System.cmd(
           "powershell",
           ["-NoProfile", "-NonInteractive", "-Command", script],
           stderr_to_stdout: false
         ) do
      {output, 0} ->
        val = String.trim(output)
        if val == "", do: nil, else: val

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp ps_lines(script) do
    case ps_value(script) do
      nil ->
        nil

      output ->
        lines =
          output
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        if lines == [], do: nil, else: lines
    end
  end

  defp cfg, do: Application.get_env(:zaq, __MODULE__, [])
end
