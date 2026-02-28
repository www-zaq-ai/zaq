defmodule Zaq.License.Verifier do
  @moduledoc """
  Verifies license payload signatures using an Ed25519 public key.
  Loads the public key from disk at runtime.
  """

  @keys_dir "priv/keys"
  @public_key_path Path.join(@keys_dir, "public.pem")

  @doc """
  Returns the public key loaded from disk.
  """
  def public_key do
    case File.read(@public_key_path) do
      {:ok, pem} -> {:ok, parse_public_pem(pem)}
      {:error, :enoent} -> {:error, :no_public_key}
    end
  end

  @doc """
  Verifies a payload against a signature using the public key.
  Returns :ok or {:error, reason}.
  """
  def verify(payload, signature) when is_binary(payload) and is_binary(signature) do
    case public_key() do
      {:ok, pub} ->
        case :crypto.verify(:eddsa, :none, payload, signature, [pub, :ed25519]) do
          true -> :ok
          false -> {:error, :invalid_signature}
        end

      error ->
        error
    end
  end

  @doc """
  Parses a raw PEM string into a 32-byte Ed25519 public key binary.
  """
  def parse_public_pem(pem) do
    pem
    |> String.trim()
    |> String.replace("-----BEGIN ED25519 PUBLIC KEY-----", "")
    |> String.replace("-----END ED25519 PUBLIC KEY-----", "")
    |> String.replace(~r/\s+/, "")
    |> Base.decode64!()
  end
end
