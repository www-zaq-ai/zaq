defmodule Zaq.Types.EncryptedStringTest do
  use ExUnit.Case, async: false

  alias Zaq.System.SecretConfig
  alias Zaq.Types.EncryptedString

  setup do
    previous = Application.get_env(:zaq, Zaq.System.SecretConfig, [])

    Application.put_env(
      :zaq,
      Zaq.System.SecretConfig,
      encryption_key: Base.encode64(:crypto.strong_rand_bytes(32)),
      key_id: "test-v1"
    )

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.System.SecretConfig, previous)
    end)

    :ok
  end

  test "type/0 returns :string" do
    assert :string = EncryptedString.type()
  end

  describe "delegates" do
    test "encrypt/1 and decrypt/1 round-trip" do
      assert {:ok, encrypted} = EncryptedString.encrypt("smtp-secret")
      assert {:ok, "smtp-secret"} = EncryptedString.decrypt(encrypted)
    end

    test "encrypted?/1 returns true for encrypted payload" do
      assert {:ok, encrypted} = SecretConfig.encrypt("smtp-secret")
      assert EncryptedString.encrypted?(encrypted)
    end
  end

  describe "decrypt!/1" do
    test "returns nil for nil, empty and masked values" do
      assert is_nil(EncryptedString.decrypt!(nil))
      assert is_nil(EncryptedString.decrypt!(""))
      assert is_nil(EncryptedString.decrypt!("••••••••"))
    end

    test "returns plaintext for valid encrypted payload" do
      assert {:ok, encrypted} = SecretConfig.encrypt("smtp-secret")
      assert "smtp-secret" = EncryptedString.decrypt!(encrypted)
    end

    test "returns nil for invalid encrypted payload" do
      assert is_nil(EncryptedString.decrypt!("enc:test-v1:not-base64"))
    end
  end

  describe "cast/1" do
    test "accepts nil and binaries" do
      assert {:ok, nil} = EncryptedString.cast(nil)
      assert {:ok, "plain"} = EncryptedString.cast("plain")
    end

    test "rejects non-binary values" do
      assert :error = EncryptedString.cast(123)
    end
  end

  describe "load/1" do
    test "returns nil for nil" do
      assert {:ok, nil} = EncryptedString.load(nil)
    end

    test "decrypts encrypted value" do
      assert {:ok, encrypted} = SecretConfig.encrypt("smtp-secret")
      assert {:ok, "smtp-secret"} = EncryptedString.load(encrypted)
    end

    test "keeps backward-compatible plaintext values" do
      assert {:ok, "legacy-plaintext"} = EncryptedString.load("legacy-plaintext")
    end

    test "returns {:ok, nil} on decryption failure" do
      assert {:ok, nil} = EncryptedString.load("enc:test-v1:not-base64")
    end
  end

  describe "dump/1" do
    test "returns nil and empty string unchanged" do
      assert {:ok, nil} = EncryptedString.dump(nil)
      assert {:ok, ""} = EncryptedString.dump("")
    end

    test "encrypts plaintext binaries" do
      assert {:ok, encrypted} = EncryptedString.dump("smtp-secret")
      assert EncryptedString.encrypted?(encrypted)
      assert {:ok, "smtp-secret"} = SecretConfig.decrypt(encrypted)
    end

    test "keeps already encrypted value unchanged" do
      assert {:ok, encrypted} = SecretConfig.encrypt("smtp-secret")
      assert {:ok, ^encrypted} = EncryptedString.dump(encrypted)
    end

    test "returns :error when encryption fails" do
      previous = Application.get_env(:zaq, Zaq.System.SecretConfig, [])
      Application.put_env(:zaq, Zaq.System.SecretConfig, [])

      assert :error = EncryptedString.dump("smtp-secret")

      Application.put_env(:zaq, Zaq.System.SecretConfig, previous)
    end

    test "returns :error for non-binary values" do
      assert :error = EncryptedString.dump(123)
    end
  end
end
