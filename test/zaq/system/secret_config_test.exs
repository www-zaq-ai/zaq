defmodule Zaq.System.SecretConfigTest do
  use ExUnit.Case, async: false

  alias Zaq.System.SecretConfig

  setup do
    previous = Application.get_env(:zaq, Zaq.System.SecretConfig, [])

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.System.SecretConfig, previous)
    end)

    :ok
  end

  describe "encrypt/1 and decrypt/1" do
    test "round-trips plaintext with configured key" do
      Application.put_env(
        :zaq,
        Zaq.System.SecretConfig,
        encryption_key: Base.encode64(:crypto.strong_rand_bytes(32)),
        key_id: "test-v1"
      )

      assert {:ok, encrypted} = SecretConfig.encrypt("smtp-secret")
      assert String.starts_with?(encrypted, "enc:test-v1:")
      assert {:ok, "smtp-secret"} = SecretConfig.decrypt(encrypted)
    end

    test "decrypt keeps backward-compatible plaintext values" do
      assert {:ok, "legacy-plaintext"} = SecretConfig.decrypt("legacy-plaintext")
    end

    test "returns missing_encryption_key when key is not configured" do
      Application.put_env(:zaq, Zaq.System.SecretConfig, [])

      assert {:error, :missing_encryption_key} = SecretConfig.encrypt("smtp-secret")
    end
  end

  describe "validate_encryption_key/1 (boot validation)" do
    test "accepts a base64 key decoding to 32 bytes" do
      assert :ok =
               SecretConfig.validate_encryption_key(Base.encode64(:crypto.strong_rand_bytes(32)))
    end

    test "accepts a raw 32-byte key" do
      assert :ok = SecretConfig.validate_encryption_key(:crypto.strong_rand_bytes(32))
    end

    test "accepts a 64-char hex key" do
      assert :ok =
               SecretConfig.validate_encryption_key(Base.encode16(:crypto.strong_rand_bytes(32)))
    end

    test "rejects nil and empty as missing" do
      assert {:error, :missing_encryption_key} = SecretConfig.validate_encryption_key(nil)
      assert {:error, :missing_encryption_key} = SecretConfig.validate_encryption_key("")
    end

    test "rejects a key that does not represent 32 bytes" do
      assert {:error, :invalid_encryption_key} =
               SecretConfig.validate_encryption_key(Base.encode64(:crypto.strong_rand_bytes(16)))
    end

    test "does not read application config" do
      Application.put_env(:zaq, Zaq.System.SecretConfig, [])

      assert :ok =
               SecretConfig.validate_encryption_key(Base.encode64(:crypto.strong_rand_bytes(32)))
    end
  end
end
