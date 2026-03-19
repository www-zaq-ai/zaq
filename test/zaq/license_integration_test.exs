defmodule Zaq.License.IntegrationTest do
  @moduledoc """
  End-to-end test: generate a license package, then load and verify it
  inside the zaq client. Simulates the full flow without needing
  the license_manager project running.
  """

  use ExUnit.Case, async: false
  @moduletag :integration

  import ExUnit.CaptureLog

  alias Zaq.License.{BeamDecryptor, FeatureStore, Loader}

  @keys_dir "priv/keys"
  @private_key_path Path.join(@keys_dir, "private.pem")
  @public_key_path Path.join(@keys_dir, "public.pem")

  setup do
    # Start FeatureStore if not already running
    case GenServer.whereis(FeatureStore) do
      nil -> start_supervised!(FeatureStore)
      _pid -> FeatureStore.clear()
    end

    # Generate a fresh key pair for testing
    File.mkdir_p!(@keys_dir)
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    private_pem = """
    -----BEGIN ED25519 PRIVATE KEY-----
    #{Base.encode64(priv <> pub)}
    -----END ED25519 PRIVATE KEY-----
    """

    public_pem = """
    -----BEGIN ED25519 PUBLIC KEY-----
    #{Base.encode64(pub)}
    -----END ED25519 PUBLIC KEY-----
    """

    File.write!(@private_key_path, String.trim(private_pem))
    File.write!(@public_key_path, String.trim(public_pem))

    tmp_dir = Path.join(System.tmp_dir!(), "zaq_license_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      FeatureStore.clear()
    end)

    {:ok, priv: priv, pub: pub, tmp_dir: tmp_dir}
  end

  describe "full license flow" do
    test "generates, loads, and calls paid modules", %{priv: priv, tmp_dir: tmp_dir} do
      # 1. Create a test BEAM module in memory
      module_code = """
      defmodule LicenseManager.Paid.Ontology do
        def classify(text), do: {:ok, "classified: \#{text}"}
      end
      """

      [{_module, beam_binary}] = Code.compile_string(module_code)

      # 2. Build license payload
      payload =
        Jason.encode!(%{
          license_key: "lic_test_001",
          company: %{id: "company-uuid", name: "Test Corp"},
          features: [
            %{name: "ontology", module_tags: ["Elixir.LicenseManager.Paid.Ontology"]}
          ],
          issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          expires_at: DateTime.utc_now() |> DateTime.add(86_400) |> DateTime.to_iso8601(),
          max_users: 10
        })

      # 3. Sign payload
      signature = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])

      # 4. Encrypt the BEAM binary
      key = BeamDecryptor.derive_key(payload)
      iv = :crypto.strong_rand_bytes(12)

      {encrypted, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, beam_binary, "zaq-beam-v1", 16, true)

      encrypted_beam = iv <> tag <> encrypted

      # 5. Build license.dat
      license_dat = Base.encode64(payload) <> "." <> Base.encode64(signature)

      # 6. Create tar.gz package
      license_path = Path.join(tmp_dir, "test.zaq-license")

      :erl_tar.create(
        String.to_charlist(license_path),
        [
          {~c"license.dat", license_dat},
          {~c"modules/Elixir.LicenseManager.Paid.Ontology.beam.enc", encrypted_beam}
        ],
        [:compressed]
      )

      # 7. Load the license
      assert {:ok, license_data} = Loader.load(license_path)
      assert license_data["license_key"] == "lic_test_001"
      assert license_data["company"]["name"] == "Test Corp"

      # 8. Verify module is callable
      module = Module.concat([LicenseManager, Paid, Ontology])
      assert {:ok, "classified: hello"} = module.classify("hello")

      # 9. Verify FeatureStore
      assert FeatureStore.feature_loaded?("ontology")
      assert FeatureStore.module_loaded?(module)
    end

    test "loading a license with an ObanFeature module twice does not crash (idempotent)", %{
      priv: priv,
      tmp_dir: tmp_dir
    } do
      mod_name =
        "Elixir.LicenseManager.Paid.IdempotentOban#{System.unique_integer([:positive])}"

      queue = :"integration_idempotent_q_#{System.unique_integer([:positive])}"

      module_code = """
      defmodule #{mod_name} do
        @behaviour Zaq.License.ObanFeature
        def oban_queues, do: [{:#{queue}, 1}]
        def oban_crontab, do: []
      end
      """

      [{_mod, beam_binary}] = Code.compile_string(module_code)

      payload =
        Jason.encode!(%{
          license_key: "lic_idempotent",
          company: %{id: "cid", name: "Idem Corp"},
          features: [],
          issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          expires_at: DateTime.utc_now() |> DateTime.add(86_400) |> DateTime.to_iso8601(),
          max_users: 5
        })

      signature = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])
      key = BeamDecryptor.derive_key(payload)
      iv = :crypto.strong_rand_bytes(12)

      {encrypted, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, beam_binary, "zaq-beam-v1", 16, true)

      encrypted_beam = iv <> tag <> encrypted
      license_dat = Base.encode64(payload) <> "." <> Base.encode64(signature)
      license_path = Path.join(tmp_dir, "idempotent.zaq-license")

      :erl_tar.create(
        String.to_charlist(license_path),
        [
          {~c"license.dat", license_dat},
          {String.to_charlist("modules/#{mod_name}.beam.enc"), encrypted_beam}
        ],
        [:compressed]
      )

      capture_log(fn ->
        assert {:ok, _} = Loader.load(license_path)
        # Second load must not raise even though start_queue is called again
        assert {:ok, _} = Loader.load(license_path)
      end)
    end

    test "rejects expired license", %{priv: priv, tmp_dir: tmp_dir} do
      payload =
        Jason.encode!(%{
          license_key: "lic_expired",
          company: %{id: "company-uuid", name: "Expired Corp"},
          features: [],
          issued_at: DateTime.utc_now() |> DateTime.add(-172_800) |> DateTime.to_iso8601(),
          expires_at: DateTime.utc_now() |> DateTime.add(-86_400) |> DateTime.to_iso8601(),
          max_users: 5
        })

      signature = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])
      license_dat = Base.encode64(payload) <> "." <> Base.encode64(signature)

      license_path = Path.join(tmp_dir, "expired.zaq-license")

      :erl_tar.create(
        String.to_charlist(license_path),
        [{~c"license.dat", license_dat}],
        [:compressed]
      )

      capture_log(fn ->
        assert {:error, :license_expired} = Loader.load(license_path)
      end)
    end

    test "rejects tampered payload", %{priv: priv, tmp_dir: tmp_dir} do
      payload =
        Jason.encode!(%{
          license_key: "lic_tampered",
          company: %{id: "company-uuid", name: "Tamper Corp"},
          features: [],
          issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          expires_at: DateTime.utc_now() |> DateTime.add(86_400) |> DateTime.to_iso8601(),
          max_users: 5
        })

      # Sign original payload but tamper it after
      signature = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])

      tampered_payload =
        Jason.encode!(%{
          license_key: "lic_tampered",
          company: %{id: "company-uuid", name: "Tamper Corp"},
          features: [],
          issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          expires_at: DateTime.utc_now() |> DateTime.add(86_400) |> DateTime.to_iso8601(),
          max_users: 9999
        })

      license_dat = Base.encode64(tampered_payload) <> "." <> Base.encode64(signature)

      license_path = Path.join(tmp_dir, "tampered.zaq-license")

      :erl_tar.create(
        String.to_charlist(license_path),
        [{~c"license.dat", license_dat}],
        [:compressed]
      )

      capture_log(fn ->
        assert {:error, :invalid_signature} = Loader.load(license_path)
      end)
    end

    test "rejects license signed with wrong key", %{tmp_dir: tmp_dir} do
      {_wrong_pub, wrong_priv} = :crypto.generate_key(:eddsa, :ed25519)

      payload =
        Jason.encode!(%{
          license_key: "lic_wrong_key",
          company: %{id: "company-uuid", name: "Wrong Key Corp"},
          features: [],
          issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          expires_at: DateTime.utc_now() |> DateTime.add(86_400) |> DateTime.to_iso8601(),
          max_users: 5
        })

      signature = :crypto.sign(:eddsa, :none, payload, [wrong_priv, :ed25519])
      license_dat = Base.encode64(payload) <> "." <> Base.encode64(signature)

      license_path = Path.join(tmp_dir, "wrong_key.zaq-license")

      :erl_tar.create(
        String.to_charlist(license_path),
        [{~c"license.dat", license_dat}],
        [:compressed]
      )

      capture_log(fn ->
        assert {:error, :invalid_signature} = Loader.load(license_path)
      end)
    end
  end
end
