defmodule Zaq.License.BeamDecryptorTest do
  use ExUnit.Case, async: true

  alias Zaq.License.BeamDecryptor

  test "derive_key is deterministic sha256" do
    payload = "license-payload"

    assert BeamDecryptor.derive_key(payload) == :crypto.hash(:sha256, payload)
    assert byte_size(BeamDecryptor.derive_key(payload)) == 32
  end

  test "decrypt returns plaintext for valid ciphertext" do
    payload = "{\"license\":\"x\"}"
    key = BeamDecryptor.derive_key(payload)
    iv = <<0::96>>
    plaintext = "compiled-beam-binary"

    {encrypted, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, "zaq-beam-v1", 16, true)

    ciphertext = iv <> tag <> encrypted

    assert {:ok, ^plaintext} = BeamDecryptor.decrypt(ciphertext, key)
  end

  test "decrypt returns error for tampered ciphertext" do
    payload = "{\"license\":\"x\"}"
    key = BeamDecryptor.derive_key(payload)
    iv = <<1::96>>
    plaintext = "compiled-beam-binary"

    {encrypted, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, "zaq-beam-v1", 16, true)

    tampered_tag = :binary.part(tag, 0, 15) <> <<:erlang.bxor(:binary.last(tag), 1)>>
    ciphertext = iv <> tampered_tag <> encrypted

    assert {:error, :decryption_failed} = BeamDecryptor.decrypt(ciphertext, key)
  end
end
