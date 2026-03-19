defmodule Zaq.License.LicenseIntegrationTest do
  @moduledoc """
  Integration tests for the full license load pipeline:
  Loader → BeamDecryptor → FeatureStore → ObanProvisioner.

  Tagged :integration so they are excluded from the default test run.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

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
      Path.join(
        System.tmp_dir!(),
        "zaq_integration_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      FeatureStore.clear()
      File.rm_rf!(tmp_dir)
      Logger.configure(level: :warning)

      case original_key do
        {:ok, content} -> File.write!(@public_key_path, content)
        :missing -> File.rm(@public_key_path)
      end
    end)

    {:ok, tmp_dir: tmp_dir, priv: priv}
  end

  test "full pipeline: valid license loads modules and updates feature store", %{
    tmp_dir: tmp_dir,
    priv: priv
  } do
    module_name =
      "Elixir.LicenseManager.Paid.IntegrationSuccess#{System.unique_integer([:positive])}"

    module_source = """
    defmodule #{module_name} do
      def enabled?, do: true
    end
    """

    [{_mod, beam_binary}] = Code.compile_string(module_source)

    payload =
      Jason.encode!(%{
        "license_key" => "int_ok",
        "features" => [%{"name" => "integration_feature"}],
        "expires_at" =>
          DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_iso8601()
      })

    signature = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])
    key = BeamDecryptor.derive_key(payload)

    {encrypted, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        <<1::96>>,
        beam_binary,
        "zaq-beam-v1",
        16,
        true
      )

    encrypted_module = <<1::96>> <> tag <> encrypted
    path = Path.join(tmp_dir, "integration_ok.zaq-license")

    create_archive!(path, [
      {~c"license.dat", Base.encode64(payload) <> "." <> Base.encode64(signature)},
      {String.to_charlist("modules/#{module_name}.beam.enc"), encrypted_module}
    ])

    capture_log(fn ->
      assert {:ok, license_data} = Loader.load(path)
      assert license_data["license_key"] == "int_ok"
    end)

    assert FeatureStore.feature_loaded?("integration_feature")
    assert FeatureStore.module_loaded?(String.to_atom(module_name))
  end

  test "full pipeline: ObanFeature module triggers ObanProvisioner", %{
    tmp_dir: tmp_dir,
    priv: priv
  } do
    mod_name =
      "Elixir.LicenseManager.Paid.IntegrationObanFeature#{System.unique_integer([:positive])}"

    queue = :"integration_test_q_#{System.unique_integer([:positive])}"

    module_source = """
    defmodule #{mod_name} do
      @behaviour Zaq.License.ObanFeature
      def oban_queues, do: [{:#{queue}, 2}]
      def oban_crontab, do: []
    end
    """

    [{_mod, beam_binary}] = Code.compile_string(module_source)

    payload =
      Jason.encode!(%{
        "license_key" => "int_oban",
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
        <<2::96>>,
        beam_binary,
        "zaq-beam-v1",
        16,
        true
      )

    encrypted_module = <<2::96>> <> tag <> encrypted
    path = Path.join(tmp_dir, "integration_oban.zaq-license")

    create_archive!(path, [
      {~c"license.dat", Base.encode64(payload) <> "." <> Base.encode64(signature)},
      {String.to_charlist("modules/#{mod_name}.beam.enc"), encrypted_module}
    ])

    Logger.configure(level: :info)

    log =
      capture_log(fn ->
        assert {:ok, _} = Loader.load(path)
      end)

    Logger.configure(level: :warning)

    assert log =~ "queue :#{queue}"
  end

  test "pipeline returns error for expired license without touching feature store", %{
    tmp_dir: tmp_dir,
    priv: priv
  } do
    payload =
      Jason.encode!(%{
        "license_key" => "int_expired",
        "features" => [%{"name" => "should_not_load"}],
        "expires_at" => DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
      })

    signature = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])
    path = Path.join(tmp_dir, "integration_expired.zaq-license")

    create_archive!(path, [
      {~c"license.dat", Base.encode64(payload) <> "." <> Base.encode64(signature)}
    ])

    capture_log(fn ->
      assert {:error, :license_expired} = Loader.load(path)
    end)

    refute FeatureStore.feature_loaded?("should_not_load")
  end

  # --- Helpers ---

  defp create_archive!(path, entries) do
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
  end

  defp ensure_started(module) do
    case GenServer.whereis(module) do
      nil -> start_supervised!(module)
      _pid -> :ok
    end
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
