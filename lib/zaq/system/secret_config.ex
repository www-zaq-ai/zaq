defmodule Zaq.System.SecretConfig do
  @moduledoc """
  Encrypts and decrypts sensitive system configuration values.

  This module is currently used for SMTP password protection at rest.

  Configuration is read from:

      config :zaq, Zaq.System.SecretConfig,
        encryption_key: System.get_env("SYSTEM_CONFIG_ENCRYPTION_KEY"),
        key_id: System.get_env("SYSTEM_CONFIG_ENCRYPTION_KEY_ID", "v1")

  `encryption_key` must represent exactly 32 bytes and supports:

  - raw 32-byte value
  - base64 value decoding to 32 bytes
  - 64-char hex value (32 bytes)

  Encrypted payloads are stored in this format:

      enc:<key_id>:<nonce_b64>:<tag_b64>:<ciphertext_b64>

  Backward compatibility: plaintext values remain readable via `decrypt/1`.
  """

  @algo :aes_256_gcm
  @aad "zaq.system.secret_config"
  @default_key_id "v1"
  @prefix "enc"
  @nonce_size 12

  @doc """
  Encrypts a plaintext value using AES-256-GCM.

  Returns `{:ok, encrypted_payload}` or:

  - `{:error, :missing_encryption_key}` when no key is configured
  - `{:error, :invalid_encryption_key}` when key format/size is invalid
  """
  @spec encrypt(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def encrypt(value) when is_binary(value) do
    with {:ok, key, key_id} <- fetch_key_material() do
      nonce = :crypto.strong_rand_bytes(@nonce_size)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(@algo, key, nonce, value, @aad, true)

      {:ok,
       Enum.join(
         [
           @prefix,
           key_id,
           Base.encode64(nonce, padding: false),
           Base.encode64(tag, padding: false),
           Base.encode64(ciphertext, padding: false)
         ],
         ":"
       )}
    end
  end

  @doc """
  Decrypts a stored value.

  - If value is encrypted (`enc:...`), attempts decryption.
  - If value is plaintext, returns it unchanged for backward compatibility.
  - `nil` remains `nil`.
  """
  @spec decrypt(nil | String.t()) :: {:ok, nil | String.t()} | {:error, atom() | tuple()}
  def decrypt(nil), do: {:ok, nil}

  def decrypt(value) when is_binary(value) do
    if encrypted?(value) do
      decrypt_encrypted(value)
    else
      {:ok, value}
    end
  end

  @doc "Returns `true` when value uses the `enc:` payload format."
  @spec encrypted?(String.t()) :: boolean()
  def encrypted?(value) when is_binary(value), do: String.starts_with?(value, "#{@prefix}:")

  defp decrypt_encrypted(value) do
    with [@prefix, key_id, nonce_b64, tag_b64, ciphertext_b64] <- String.split(value, ":"),
         {:ok, key, configured_key_id} <- fetch_key_material(),
         :ok <- ensure_key_id(key_id, configured_key_id),
         {:ok, nonce} <- Base.decode64(nonce_b64, padding: false),
         {:ok, tag} <- Base.decode64(tag_b64, padding: false),
         {:ok, ciphertext} <- Base.decode64(ciphertext_b64, padding: false),
         plaintext <-
           :crypto.crypto_one_time_aead(@algo, key, nonce, ciphertext, @aad, tag, false),
         true <- is_binary(plaintext) do
      {:ok, plaintext}
    else
      :error -> {:error, :invalid_ciphertext}
      false -> {:error, :invalid_ciphertext}
      {:error, _} = error -> error
      _ -> {:error, :invalid_ciphertext}
    end
  end

  defp ensure_key_id(key_id, key_id), do: :ok
  defp ensure_key_id(payload_key_id, _), do: {:error, {:unknown_key_id, payload_key_id}}

  defp fetch_key_material do
    config = Application.get_env(:zaq, __MODULE__, [])
    key_id = Keyword.get(config, :key_id, @default_key_id)

    case Keyword.get(config, :encryption_key) do
      nil -> {:error, :missing_encryption_key}
      "" -> {:error, :missing_encryption_key}
      key -> normalize_key(key, key_id)
    end
  end

  defp normalize_key(key, key_id) do
    cond do
      byte_size(key) == 32 ->
        {:ok, key, key_id}

      String.length(key) == 64 and String.match?(key, ~r/^[0-9a-fA-F]+$/) ->
        case Base.decode16(key, case: :mixed) do
          {:ok, decoded} when byte_size(decoded) == 32 -> {:ok, decoded, key_id}
          _ -> {:error, :invalid_encryption_key}
        end

      true ->
        case Base.decode64(key) do
          {:ok, decoded} when byte_size(decoded) == 32 -> {:ok, decoded, key_id}
          _ -> {:error, :invalid_encryption_key}
        end
    end
  end
end
