defmodule Zaq.Types.EncryptedString do
  @moduledoc """
  Custom Ecto type that transparently encrypts values on write and decrypts on read.

  - `cast/1`  — keeps the plaintext value in changesets so forms display correctly.
  - `dump/1`  — encrypts before writing to the database.
  - `load/1`  — decrypts after reading from the database. Plaintext values (legacy
                rows saved before encryption was introduced) are returned as-is for
                backward compatibility, matching `Zaq.System.SecretConfig.decrypt/1`.

  Encryption failures in `dump/1` return `:error`, which causes the changeset to
  fail. Decryption failures in `load/1` return `{:ok, nil}` so records with a
  corrupted token still load without crashing.
  """

  use Ecto.Type

  alias Zaq.System.SecretConfig

  @doc "Encrypts a plaintext value. Returns `{:ok, encrypted}` or `{:error, reason}`."
  defdelegate encrypt(value), to: SecretConfig

  @doc "Decrypts a stored value. Plaintext pass-through for legacy values."
  defdelegate decrypt(value), to: SecretConfig

  @doc "Returns `true` when value uses the `enc:` payload format."
  defdelegate encrypted?(value), to: SecretConfig

  @doc """
  Decrypts a stored value, returning the plaintext string directly.
  Returns `nil` for `nil`, `""`, or any decryption error.
  """
  def decrypt!(nil), do: nil
  def decrypt!(""), do: nil
  def decrypt!("••••••••"), do: nil

  def decrypt!(value) when is_binary(value) do
    case decrypt(value) do
      {:ok, decrypted} -> decrypted
      {:error, _} -> nil
    end
  end

  @impl Ecto.Type
  def type, do: :string

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_), do: :error

  @impl Ecto.Type
  def load(nil), do: {:ok, nil}

  def load(value) when is_binary(value) do
    case SecretConfig.decrypt(value) do
      {:ok, decrypted} -> {:ok, decrypted}
      {:error, _} -> {:ok, nil}
    end
  end

  @impl Ecto.Type
  def dump(nil), do: {:ok, nil}
  def dump(""), do: {:ok, ""}

  def dump(value) when is_binary(value) do
    if SecretConfig.encrypted?(value) do
      {:ok, value}
    else
      case SecretConfig.encrypt(value) do
        {:ok, encrypted} -> {:ok, encrypted}
        {:error, _} -> :error
      end
    end
  end

  def dump(_), do: :error
end
