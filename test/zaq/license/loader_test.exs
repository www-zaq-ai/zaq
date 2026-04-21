defmodule Zaq.License.LoaderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Zaq.License.{BeamDecryptor, FeatureStore, LicensePostLoader, Loader}

  @public_key_path Path.join(["priv", "keys", "public.pem"])

  setup do
    ensure_started(FeatureStore)
    ensure_started(LicensePostLoader)
    FeatureStore.clear()

    File.mkdir_p!(Path.dirname(@public_key_path))

    original_key =
      case File.read(@public_key_path) do
        {:ok, content} -> {:ok, content}
        {:error, :enoent} -> :missing
      end

    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    write_public_key(pub)

    tmp_dir =
      Path.join(System.tmp_dir!(), "zaq_loader_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      FeatureStore.clear()
      File.rm_rf!(tmp_dir)
      # Restore logger level in case a test raised it to :info for capture_log
      Logger.configure(level: :warning)

      case original_key do
        {:ok, content} -> File.write!(@public_key_path, content)
        :missing -> File.rm(@public_key_path)
      end
    end)

    {:ok, tmp_dir: tmp_dir, pub: pub, priv: priv}
  end

  test "returns extract_failed for non archive file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "bad.zaq-license")
    File.write!(path, "not-a-tar")

    log = capture_log(fn -> assert {:error, {:extract_failed, _reason}} = Loader.load(path) end)
    assert log =~ "extract_failed"
  end

  test "returns missing_license_dat when package lacks license.dat", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "missing_dat.zaq-license")
    create_archive!(path, [{~c"modules/Any.beam.enc", "x"}])

    log = capture_log(fn -> assert {:error, :missing_license_dat} = Loader.load(path) end)
    assert log =~ "missing_license_dat"
  end

  test "returns invalid_license_dat_format for malformed license.dat", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "bad_format.zaq-license")
    create_archive!(path, [{~c"license.dat", "only-one-part"}])

    log = capture_log(fn -> assert {:error, :invalid_license_dat_format} = Loader.load(path) end)
    assert log =~ "invalid_license_dat_format"
  end

  test "returns invalid_payload_json for non-json payload", %{
    tmp_dir: tmp_dir,
    pub: pub,
    priv: priv
  } do
    payload = "not-json"
    signature = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])

    path = Path.join(tmp_dir, "bad_json.zaq-license")

    create_archive!(path, [
      {~c"license.dat", Base.encode64(payload) <> "." <> Base.encode64(signature)},
      {~c"public.key", Base.encode64(pub)}
    ])

    log = capture_log(fn -> assert {:error, :invalid_payload_json} = Loader.load(path) end)
    assert log =~ "invalid_payload_json"
  end

  test "returns missing_expires_at when field is absent", %{
    tmp_dir: tmp_dir,
    pub: pub,
    priv: priv
  } do
    payload = Jason.encode!(%{"license_key" => "lic_missing_exp", "features" => []})
    signature = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])
    key = BeamDecryptor.derive_key(payload)
    encrypted_module = encrypt_module(paid_license_beam(), key, <<20::96>>)

    path = Path.join(tmp_dir, "missing_exp.zaq-license")

    create_archive!(path, [
      {~c"license.dat", Base.encode64(payload) <> "." <> Base.encode64(signature)},
      {~c"public.key", Base.encode64(pub)},
      {~c"modules/Elixir.LicenseManager.Paid.License.beam.enc", encrypted_module}
    ])

    log = capture_log(fn -> assert {:error, :missing_expires_at} = Loader.load(path) end)
    assert log =~ "missing_expires_at"
  end

  test "returns license_expired when expiry is in the past", %{
    tmp_dir: tmp_dir,
    pub: pub,
    priv: priv
  } do
    payload =
      Jason.encode!(%{
        "license_key" => "lic_expired",
        "features" => [],
        "expires_at" => DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.to_iso8601()
      })

    signature = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])
    key = BeamDecryptor.derive_key(payload)
    encrypted_module = encrypt_module(paid_license_beam(), key, <<21::96>>)

    path = Path.join(tmp_dir, "expired.zaq-license")

    create_archive!(path, [
      {~c"license.dat", Base.encode64(payload) <> "." <> Base.encode64(signature)},
      {~c"public.key", Base.encode64(pub)},
      {~c"modules/Elixir.LicenseManager.Paid.License.beam.enc", encrypted_module}
    ])

    log = capture_log(fn -> assert {:error, :license_expired} = Loader.load(path) end)
    assert log =~ "license_expired"
  end

  test "returns decrypt_failed when module cannot be decrypted", %{
    tmp_dir: tmp_dir,
    pub: pub,
    priv: priv
  } do
    payload = valid_payload("lic_dec_fail")
    signature = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])
    key = BeamDecryptor.derive_key(payload)

    {encrypted, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, <<9::96>>, "beam", "zaq-beam-v1", 16, true)

    bad_tag = :binary.part(tag, 0, 15) <> <<:erlang.bxor(:binary.last(tag), 1)>>
    encrypted_module = <<9::96>> <> bad_tag <> encrypted

    path = Path.join(tmp_dir, "decrypt_fail.zaq-license")

    create_archive!(path, [
      {~c"license.dat", Base.encode64(payload) <> "." <> Base.encode64(signature)},
      {~c"public.key", Base.encode64(pub)},
      {~c"modules/Elixir.LicenseManager.Paid.DecFail.beam.enc", encrypted_module}
    ])

    log =
      capture_log(fn ->
        assert {:error, {:decrypt_failed, "Elixir.LicenseManager.Paid.DecFail", :decryption_failed}} =
                 Loader.load(path)
      end)

    assert log =~ "decrypt_failed"
  end

  test "returns load_failed when decrypted bytes are not a beam file", %{
    tmp_dir: tmp_dir,
    pub: pub,
    priv: priv
  } do
    payload = valid_payload("lic_load_fail")
    signature = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])
    key = BeamDecryptor.derive_key(payload)

    {encrypted, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        <<3::96>>,
        "not-beam",
        "zaq-beam-v1",
        16,
        true
      )

    encrypted_module = <<3::96>> <> tag <> encrypted
    path = Path.join(tmp_dir, "load_fail.zaq-license")

    create_archive!(path, [
      {~c"license.dat", Base.encode64(payload) <> "." <> Base.encode64(signature)},
      {~c"public.key", Base.encode64(pub)},
      {~c"modules/Elixir.LicenseManager.Paid.LoadFail.beam.enc", encrypted_module}
    ])

    log =
      capture_log(fn ->
        assert {:error, {:load_failed, "Elixir.LicenseManager.Paid.LoadFail", _reason}} =
                 Loader.load(path)
      end)

    assert log =~ "load_failed"
  end

  test "calls ObanProvisioner when loaded module implements ObanFeature", %{
    tmp_dir: tmp_dir,
    pub: pub,
    priv: priv
  } do
    # The unique suffix keeps the module atom distinct across test runs.
    mod_name = "Elixir.LicenseManager.Paid.ObanFeatureTest#{System.unique_integer([:positive])}"

    queue = :"loader_test_oban_q_#{System.unique_integer([:positive])}"

    module_source = """
    defmodule #{mod_name} do
      @behaviour Zaq.License.ObanFeature
      def feature_key, do: :loader_test_oban_feature
      def oban_queues, do: [{:#{queue}, 1}]
      def oban_crontab, do: []
    end
    """

    [{_module, beam_binary}] = Code.compile_string(module_source)

    payload = valid_payload("lic_oban_feature")
    signature = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])
    key = BeamDecryptor.derive_key(payload)

    {encrypted, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        <<11::96>>,
        beam_binary,
        "zaq-beam-v1",
        16,
        true
      )

    encrypted_module = <<11::96>> <> tag <> encrypted
    path = Path.join(tmp_dir, "oban_feature.zaq-license")

    create_archive!(path, [
      {~c"license.dat", Base.encode64(payload) <> "." <> Base.encode64(signature)},
      {~c"public.key", Base.encode64(pub)},
      {String.to_charlist("modules/#{mod_name}.beam.enc"), encrypted_module}
    ])

    Logger.configure(level: :info)

    log = capture_log(fn -> assert {:ok, _} = Loader.load(path) end)

    # Provisioner attempted start_queue (success or failure in test mode —
    # both prove the call was made)
    assert log =~ "queue :#{queue}"
  end

  test "does not invoke ObanProvisioner for modules without ObanFeature", %{
    tmp_dir: tmp_dir,
    pub: pub,
    priv: priv
  } do
    mod_name = "Elixir.LicenseManager.Paid.NoObanFeature#{System.unique_integer([:positive])}"

    module_source = """
    defmodule #{mod_name} do
      def enabled?, do: true
    end
    """

    [{_module, beam_binary}] = Code.compile_string(module_source)

    payload = valid_payload("lic_no_oban_feature")
    signature = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])
    key = BeamDecryptor.derive_key(payload)

    {encrypted, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        <<12::96>>,
        beam_binary,
        "zaq-beam-v1",
        16,
        true
      )

    encrypted_module = <<12::96>> <> tag <> encrypted
    path = Path.join(tmp_dir, "no_oban_feature.zaq-license")

    create_archive!(path, [
      {~c"license.dat", Base.encode64(payload) <> "." <> Base.encode64(signature)},
      {~c"public.key", Base.encode64(pub)},
      {String.to_charlist("modules/#{mod_name}.beam.enc"), encrypted_module}
    ])

    Logger.configure(level: :info)

    log = capture_log(fn -> assert {:ok, _} = Loader.load(path) end)

    refute log =~ "[ObanProvisioner]"
  end

  test "loads valid package and updates feature store", %{tmp_dir: tmp_dir, pub: pub, priv: priv} do
    module_name = "Elixir.LicenseManager.Paid.LoaderSuccess#{System.unique_integer([:positive])}"

    module_source =
      """
      defmodule #{module_name} do
        def enabled?, do: true
      end
      """

    [{_module, beam_binary}] = Code.compile_string(module_source)

    payload =
      Jason.encode!(%{
        "license_key" => "lic_ok",
        "features" => [%{"name" => "ontology"}],
        "expires_at" =>
          DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()
      })

    signature = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])
    key = BeamDecryptor.derive_key(payload)

    {encrypted, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        <<7::96>>,
        beam_binary,
        "zaq-beam-v1",
        16,
        true
      )

    encrypted_module = <<7::96>> <> tag <> encrypted

    path = Path.join(tmp_dir, "ok.zaq-license")

    create_archive!(path, [
      {~c"license.dat", Base.encode64(payload) <> "." <> Base.encode64(signature)},
      {~c"public.key", Base.encode64(pub)},
      {String.to_charlist("modules/#{module_name}.beam.enc"), encrypted_module},
      {~c"migrations/20260101000000_add_thing.exs", "defmodule TempMigration do end"}
    ])

    log =
      capture_log(fn ->
        assert {:ok, license_data} = Loader.load(path)
        assert license_data["license_key"] == "lic_ok"
        :sys.get_state(GenServer.whereis(LicensePostLoader))
      end)

    assert log =~ "Migrations failed"
    assert FeatureStore.feature_loaded?("ontology")
    assert FeatureStore.module_loaded?(String.to_atom(module_name))
  end

  defp valid_payload(license_key) do
    Jason.encode!(%{
      "license_key" => license_key,
      "features" => [],
      "expires_at" => DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()
    })
  end

  defp create_archive!(path, entries) do
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
  end

  defp ensure_started(module) do
    case GenServer.whereis(module) do
      nil -> start_supervised!(module)
      _pid -> :ok
    end
  end

  defp paid_license_beam do
    module_source = """
    defmodule LicenseManager.Paid.License do
      def check_expiry(license_data) do
        case Map.fetch(license_data, "expires_at") do
          :error ->
            {:error, :missing_expires_at}

          {:ok, expires_at_str} ->
            with {:ok, expires_at, _} <- DateTime.from_iso8601(expires_at_str),
                 :gt <- DateTime.compare(expires_at, DateTime.utc_now()) do
              :ok
            else
              _ -> {:error, :license_expired}
            end
        end
      end
    end
    """

    [{_module, beam_binary}] = Code.compile_string(module_source)
    beam_binary
  end

  defp encrypt_module(beam_binary, key, nonce) do
    {encrypted, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, beam_binary, "zaq-beam-v1", 16, true)

    nonce <> tag <> encrypted
  end

  defp write_public_key(pub) do
    # Build SPKI DER for Ed25519: 12-byte OID header + 32-byte raw key.
    # parse_public_pem/1 in Verifier expects SubjectPublicKeyInfo / SPKI format.
    der = <<0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00>> <> pub
    pem = :public_key.pem_encode([{:SubjectPublicKeyInfo, der, :not_encrypted}])
    File.write!(@public_key_path, pem)
  end
end
