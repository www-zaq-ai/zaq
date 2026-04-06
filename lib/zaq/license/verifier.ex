defmodule Zaq.License.Verifier do
  @moduledoc """
  Verifies license payload signatures using an Ed25519 public key.
  The public key is expected to be a 32-byte binary extracted from the .zaq-license package.
  """

  @doc """
  Verifies a payload against a signature using a 32-byte Ed25519 public key binary.
  Returns :ok or {:error, reason}.
  """
  def verify(payload, signature, public_key)
      when is_binary(payload) and is_binary(signature) and is_binary(public_key) do
    if :crypto.verify(:eddsa, :none, payload, signature, [public_key, :ed25519]) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end
end
