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
end
