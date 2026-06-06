defmodule Zaq.Addons.PackageVerifierTest do
  use ExUnit.Case, async: true

  alias Zaq.Addons.PackageVerifier

  test "verify succeeds for valid signature" do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    payload = "{\"license_key\":\"ok\"}"
    signature = :crypto.sign(:eddsa, :none, payload, [priv, :ed25519])

    assert :ok = PackageVerifier.verify(payload, signature, pub)
  end

  test "verify returns invalid_signature for wrong signature" do
    {pub, _priv} = :crypto.generate_key(:eddsa, :ed25519)
    {_wrong_pub, wrong_priv} = :crypto.generate_key(:eddsa, :ed25519)
    payload = "{\"license_key\":\"wrong_sig\"}"
    wrong_signature = :crypto.sign(:eddsa, :none, payload, [wrong_priv, :ed25519])

    assert {:error, :invalid_signature} = PackageVerifier.verify(payload, wrong_signature, pub)
  end
end
