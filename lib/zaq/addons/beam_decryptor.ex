defmodule Zaq.Addons.BeamDecryptor do
  @moduledoc """
  Decrypts encrypted BEAM files using AES-256-GCM.
  Mirrors the encryption logic from LicenseManager.Crypto.BeamEncryptor.
  """

  @aad "zaq-beam-v1"
  @iv_size 12
  @tag_size 16

  @doc """
  Derives a 256-bit AES key from a verified license payload using SHA-256.
  """
  def derive_key(payload) when is_binary(payload) do
    :crypto.hash(:sha256, payload)
  end

  @doc """
  Decrypts an encrypted BEAM binary with AES-256-GCM.
  Expects format: iv (12 bytes) <> tag (16 bytes) <> encrypted_data.
  Returns {:ok, beam_binary} or {:error, :decryption_failed}.
  """
  def decrypt(ciphertext, key) when is_binary(ciphertext) and byte_size(key) == 32 do
    <<iv::binary-size(@iv_size), tag::binary-size(@tag_size), encrypted::binary>> = ciphertext

    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           iv,
           encrypted,
           @aad,
           tag,
           false
         ) do
      :error -> {:error, :decryption_failed}
      decrypted -> {:ok, decrypted}
    end
  end
end
