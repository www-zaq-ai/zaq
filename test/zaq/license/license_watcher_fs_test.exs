defmodule Zaq.License.LicenseWatcherFSTest do
  use ExUnit.Case, async: false

  alias Zaq.License.{BeamDecryptor, LicenseWatcherFS}

  @public_key_path Path.join(["priv", "keys", "public.pem"])

  setup do
    File.mkdir_p!(Path.dirname(@public_key_path))

    original_key =
      case File.read(@public_key_path) do
        {:ok, content} -> {:ok, content}
        {:error, :enoent} -> :missing
      end

    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    write_public_key(pub)

    tmp_dir =
      Path.join(System.tmp_dir!(), "zaq_watcher_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)

      case original_key do
        {:ok, content} -> File.write!(@public_key_path, content)
        :missing -> File.rm(@public_key_path)
      end
    end)

    {:ok, tmp_dir: tmp_dir, priv: priv}
  end

  test "status and loaded_licenses calls expose state" do
    state = %LicenseWatcherFS{
      watch_dir: "priv/licenses",
      loaded_licenses: %{"lic_1" => %{path: "a.zaq-license"}},
      license_mtimes: %{},
      status: {:ok, %{loaded: 1}}
    }

    assert {:reply, status, ^state} = LicenseWatcherFS.handle_call(:status, self(), state)
    assert status.loaded_count == 1
    assert status.licenses == ["lic_1"]

    assert {:reply, {:ok, ["lic_1"]}, ^state} =
             LicenseWatcherFS.handle_call(:loaded_licenses, self(), state)
  end

  test "unload call handles not found and found branches" do
    state = %LicenseWatcherFS{
      watch_dir: "priv/licenses",
      loaded_licenses: %{"lic_1" => %{path: "priv/licenses/lic_1.zaq-license"}},
      license_mtimes: %{"priv/licenses/lic_1.zaq-license" => {{2026, 1, 1}, {0, 0, 0}}},
      status: :ok
    }

    assert {:reply, {:error, :not_found}, ^state} =
             LicenseWatcherFS.handle_call({:unload, "missing"}, self(), state)

    assert {:reply, :ok, new_state} =
             LicenseWatcherFS.handle_call({:unload, "lic_1"}, self(), state)

    assert new_state.loaded_licenses == %{}
    assert new_state.license_mtimes == %{}
  end

  test "non license file events keep state unchanged" do
    state = %LicenseWatcherFS{
      watch_dir: "priv/licenses",
      loaded_licenses: %{},
      license_mtimes: %{}
    }

    assert {:noreply, ^state} =
             LicenseWatcherFS.handle_info(
               {:file_event, self(), {"/tmp/readme.txt", [:modified]}},
               state
             )
  end

  test "file_event stop and watcher down update status" do
    state = %LicenseWatcherFS{
      watch_dir: "priv/licenses",
      loaded_licenses: %{},
      license_mtimes: %{}
    }

    assert {:noreply, stopped_state} =
             LicenseWatcherFS.handle_info({:file_event, self(), :stop}, state)

    assert stopped_state.status == {:error, :watcher_stopped}

    crash_state = %{state | fs_pid: self()}

    assert {:noreply, down_state} =
             LicenseWatcherFS.handle_info(
               {:DOWN, make_ref(), :process, self(), :boom},
               crash_state
             )

    assert down_state.status == {:error, :watcher_crashed}
  end

  test "force_scan with empty directory sets no files status", %{tmp_dir: tmp_dir} do
    state = %LicenseWatcherFS{
      watch_dir: tmp_dir,
      loaded_licenses: %{},
      license_mtimes: %{},
      status: :starting
    }

    assert {:reply, :ok, new_state} = LicenseWatcherFS.handle_call(:force_scan, self(), state)
    assert new_state.status == {:ok, %{loaded: 0, message: "No license files found"}}
  end

  test "force_scan loads valid license file and tracks it", %{tmp_dir: tmp_dir, priv: priv} do
    license_path = Path.join(tmp_dir, "ok.zaq-license")
    create_valid_license_archive!(license_path, priv, "watcher_ok")

    state = %LicenseWatcherFS{
      watch_dir: tmp_dir,
      loaded_licenses: %{},
      license_mtimes: %{},
      status: :starting
    }

    assert {:reply, :ok, new_state} = LicenseWatcherFS.handle_call(:force_scan, self(), state)
    assert new_state.status == {:ok, %{loaded: 1}}
    assert Map.has_key?(new_state.loaded_licenses, "watcher_ok")
    assert Map.has_key?(new_state.license_mtimes, license_path)
  end

  test "force_scan reports warning when license load fails", %{tmp_dir: tmp_dir} do
    bad_license_path = Path.join(tmp_dir, "bad.zaq-license")
    create_archive!(bad_license_path, [{~c"license.dat", "invalid"}])

    state = %LicenseWatcherFS{
      watch_dir: tmp_dir,
      loaded_licenses: %{},
      license_mtimes: %{},
      status: :starting
    }

    assert {:reply, :ok, new_state} = LicenseWatcherFS.handle_call(:force_scan, self(), state)
    assert new_state.status == {:warning, %{loaded: 0, failed: 1}}
  end

  test "process_changes clears debounce ref and scans", %{tmp_dir: tmp_dir} do
    ref = Process.send_after(self(), :noop, 1_000)

    state = %LicenseWatcherFS{
      watch_dir: tmp_dir,
      loaded_licenses: %{},
      license_mtimes: %{},
      status: :starting,
      debounce_ref: ref
    }

    assert {:noreply, new_state} = LicenseWatcherFS.handle_info(:process_changes, state)
    assert is_nil(new_state.debounce_ref)
    assert new_state.status == {:ok, %{loaded: 0, message: "No license files found"}}
  end

  defp create_valid_license_archive!(path, priv, license_key) do
    module_name = "Elixir.LicenseManager.Paid.Watcher#{System.unique_integer([:positive])}"

    module_source =
      """
      defmodule #{module_name} do
        def watcher_loaded?, do: true
      end
      """

    [{_module, beam_binary}] = Code.compile_string(module_source)

    payload =
      Jason.encode!(%{
        "license_key" => license_key,
        "features" => [],
        "expires_at" =>
          DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()
      })

    signature = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])
    key = BeamDecryptor.derive_key(payload)

    {encrypted, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        <<5::96>>,
        beam_binary,
        "zaq-beam-v1",
        16,
        true
      )

    encrypted_module = <<5::96>> <> tag <> encrypted

    create_archive!(path, [
      {~c"license.dat", Base.encode64(payload) <> "." <> Base.encode64(signature)},
      {String.to_charlist("modules/#{module_name}.beam.enc"), encrypted_module}
    ])
  end

  defp create_archive!(path, entries) do
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
  end

  defp write_public_key(pub) do
    pem =
      """
      -----BEGIN ED25519 PUBLIC KEY-----
      #{Base.encode64(pub)}
      -----END ED25519 PUBLIC KEY-----
      """
      |> String.trim()

    File.write!(@public_key_path, pem)
  end
end
