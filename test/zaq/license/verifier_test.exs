defmodule Zaq.License.VerifierTest do
  use ExUnit.Case, async: false

  alias Zaq.License.Verifier

  @public_key_path Path.join(["priv", "keys", "public.pem"])

  setup do
    File.mkdir_p!(Path.dirname(@public_key_path))

    original =
      case File.read(@public_key_path) do
        {:ok, content} -> {:ok, content}
        {:error, :enoent} -> :missing
      end

    on_exit(fn ->
      case original do
        {:ok, content} -> File.write!(@public_key_path, content)
        :missing -> File.rm(@public_key_path)
      end
    end)

    :ok
  end

  test "public_key returns error when key file is missing" do
    File.rm(@public_key_path)
    assert {:error, :no_public_key} = Verifier.public_key()
  end

  test "verify returns error when public key is missing" do
    File.rm(@public_key_path)
    assert {:error, :no_public_key} = Verifier.verify("{}", "signature")
  end

  test "parse_public_pem extracts key bytes from PEM" do
    {pub, _priv} = :crypto.generate_key(:eddsa, :ed25519)
    pem = spki_pem(pub)

    assert Verifier.parse_public_pem(pem) == pub
  end

  test "verify succeeds for valid signature and public key" do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    write_public_key(pub)

    payload = "{\"license_key\":\"ok\"}"
    signature = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])

    assert :ok = Verifier.verify(payload, signature)
  end

  test "verify returns invalid_signature for wrong signature" do
    {pub, _priv} = :crypto.generate_key(:eddsa, :ed25519)
    {_wrong_pub, wrong_priv} = :crypto.generate_key(:eddsa, :ed25519)
    write_public_key(pub)

    payload = "{\"license_key\":\"wrong_sig\"}"
    wrong_signature = :crypto.sign(:eddsa, :none, payload, [wrong_priv, :ed25519])

    assert {:error, :invalid_signature} = Verifier.verify(payload, wrong_signature)
  end

  defp write_public_key(pub) do
    File.write!(@public_key_path, spki_pem(pub))
  end

  defp spki_pem(pub) do
    # SPKI DER for Ed25519: 12-byte OID header + 32-byte raw key.
    # parse_public_pem/1 expects SubjectPublicKeyInfo / SPKI format.
    der = <<0x30, 0x2A, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x03, 0x21, 0x00>> <> pub
    :public_key.pem_encode([{:SubjectPublicKeyInfo, der, :not_encrypted}])
  end
end
