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

    pem =
      """
      -----BEGIN ED25519 PUBLIC KEY-----
      #{Base.encode64(pub)}
      -----END ED25519 PUBLIC KEY-----
      """

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
