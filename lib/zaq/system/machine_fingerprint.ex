defmodule Zaq.System.MachineFingerprint do
  @moduledoc false

  @fingerprint_length 32
  @install_id_file "machine_fingerprint_id"

  @doc """
  Returns a stable, unique identifier for this Zaq server instance.

  Derived from OS machine identifiers when available. If the host does not
  expose a usable machine identifier, a local installation identifier is
  generated once and reused.

  Returns a 32-character lowercase hex string.
  """
  @spec get() :: String.t()
  def get do
    case machine_identifier() do
      {source, identifier} -> fingerprint(source, identifier)
      nil -> fingerprint(:zaq_install_id, persisted_install_id())
    end
  end

  defp machine_identifier do
    cfg = Application.get_env(:zaq, __MODULE__, [])

    identifiers =
      case Keyword.get(cfg, :os_type, :os.type()) do
        {:unix, :linux} ->
          machine_id_paths =
            Keyword.get(cfg, :machine_id_paths, [
              "/etc/machine-id",
              "/var/lib/dbus/machine-id"
            ])

          product_uuid_path =
            Keyword.get(cfg, :product_uuid_path, "/sys/class/dmi/id/product_uuid")

          [
            {:linux_machine_id, read_first_file(machine_id_paths)},
            {:linux_product_uuid, read_file(product_uuid_path)}
          ]

        {:unix, :darwin} ->
          [{:macos_platform_uuid, macos_platform_uuid(cfg)}]

        {:win32, _name} ->
          [{:windows_machine_guid, windows_machine_guid(cfg)}]

        _ ->
          []
      end

    Enum.find_value(identifiers, fn {source, value} ->
      case normalize_identifier(value) do
        nil -> nil
        identifier -> {source, identifier}
      end
    end)
  end

  defp read_first_file(paths) do
    Enum.find_value(paths, &read_file/1)
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, value} -> value
      {:error, _reason} -> nil
    end
  end

  defp macos_platform_uuid(cfg) do
    case system_cmd(cfg, "ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        parse_macos_platform_uuid(output)

      {_output, _status} ->
        nil
    end
  rescue
    ErlangError -> nil
  end

  defp parse_macos_platform_uuid(output) do
    output
    |> String.split("\n")
    |> Enum.find_value(&parse_macos_platform_uuid_line/1)
  end

  defp parse_macos_platform_uuid_line(line) do
    case Regex.run(~r/"IOPlatformUUID"\s*=\s*"([^"]+)"/, line) do
      [_, uuid] -> uuid
      _ -> nil
    end
  end

  defp windows_machine_guid(cfg) do
    case system_cmd(cfg, "reg", [
           "query",
           "HKLM\\SOFTWARE\\Microsoft\\Cryptography",
           "/v",
           "MachineGuid"
         ]) do
      {output, 0} ->
        parse_windows_machine_guid(output)

      {_output, _status} ->
        nil
    end
  rescue
    ErlangError -> nil
  end

  defp system_cmd(cfg, command, args, opts \\ []) do
    cmd_fun = Keyword.get(cfg, :system_cmd, &System.cmd/3)
    cmd_fun.(command, args, opts)
  end

  defp parse_windows_machine_guid(output) do
    output
    |> String.split("\n")
    |> Enum.find_value(&parse_windows_machine_guid_line/1)
  end

  defp parse_windows_machine_guid_line(line) do
    case Regex.run(~r/MachineGuid\s+REG_SZ\s+(.+)$/, line) do
      [_, guid] -> guid
      _ -> nil
    end
  end

  defp persisted_install_id do
    path = install_id_path()

    with {:ok, value} <- File.read(path),
         identifier when is_binary(identifier) <- normalize_identifier(value) do
      identifier
    else
      _ ->
        identifier = Ecto.UUID.generate()
        :ok = File.mkdir_p(Path.dirname(path))
        :ok = File.write(path, identifier)
        identifier
    end
  end

  defp install_id_path do
    :filename.basedir(:user_data, "zaq")
    |> to_string()
    |> Path.join(@install_id_file)
  end

  defp normalize_identifier(nil), do: nil

  defp normalize_identifier(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      nil
    else
      String.downcase(value)
    end
  end

  defp fingerprint(source, identifier) do
    "zaq-machine-fingerprint-v1:#{source}:#{identifier}"
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, @fingerprint_length)
  end
end
