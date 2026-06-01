defmodule Zaq.Engine.ConnectEncryptionErrorTest do
  @moduledoc "Tests Connect credential encryption failures and user-facing errors."

  use Zaq.DataCase, async: false

  alias Zaq.Engine.Connect
  alias Zaq.Repo

  describe "encryption error handling" do
    setup do
      original = Application.get_env(:zaq, Zaq.System.SecretConfig)

      Application.put_env(:zaq, Zaq.System.SecretConfig,
        encryption_key: nil,
        key_id: "v1"
      )

      on_exit(fn ->
        if original do
          Application.put_env(:zaq, Zaq.System.SecretConfig, original)
        end
      end)

      :ok
    end

    test "create_credential accepts blank client_secret without encrypting it" do
      assert {:ok, credential} =
               Connect.create_credential(%{
                 name: "Blank secret",
                 provider: "google_drive",
                 auth_kind: "oauth2",
                 request_format: "bearer",
                 user_level: false,
                 metadata: %{},
                 client_id: "my-client",
                 client_secret: ""
               })

      assert Repo.get!(Connect.Credential, credential.id).client_secret == nil
    end

    test "create_credential fails with missing encryption key error" do
      assert {:error, changeset} =
               Connect.create_credential(%{
                 name: "Encrypt fail",
                 provider: "google_drive",
                 auth_kind: "oauth2",
                 request_format: "bearer",
                 user_level: false,
                 metadata: %{},
                 client_id: "my-client",
                 client_secret: "super-secret"
               })

      errors = changeset.errors

      assert keyword_has_key_value?(errors, :client_secret, fn error ->
               error
               |> error_message()
               |> String.contains?("could not be encrypted")
             end)
    end

    test "create_credential returns invalid encryption key error message" do
      Application.put_env(:zaq, Zaq.System.SecretConfig,
        encryption_key: "invalid",
        key_id: "v1"
      )

      assert {:error, changeset} =
               Connect.create_credential(%{
                 name: "Encrypt fail invalid",
                 provider: "google_drive",
                 auth_kind: "oauth2",
                 request_format: "bearer",
                 user_level: false,
                 metadata: %{},
                 client_id: "my-client",
                 client_secret: "super-secret"
               })

      errors = changeset.errors

      assert keyword_has_key_value?(errors, :client_secret, fn error ->
               error
               |> error_message()
               |> String.contains?("could not be encrypted: invalid SYSTEM_CONFIG_ENCRYPTION_KEY")
             end)
    end

    test "create_credential returns generic encryption error when encrypt fails unexpectedly" do
      with_encrypted_string_stub(fn ->
        assert {:error, changeset} =
                 Connect.create_credential(%{
                   name: "Encrypt fail boom",
                   provider: "google_drive",
                   auth_kind: "oauth2",
                   request_format: "bearer",
                   user_level: false,
                   metadata: %{},
                   client_id: "my-client",
                   client_secret: "super-secret"
                 })

        assert hd(errors_on(changeset).client_secret) == "could not be encrypted"
      end)
    end
  end

  defp keyword_has_key_value?(keyword, key, predicate) do
    case Keyword.fetch(keyword, key) do
      {:ok, value} -> predicate.(value)
      :error -> false
    end
  end

  defp error_message({message, _opts}) when is_binary(message), do: message
  defp error_message(message) when is_binary(message), do: message
  defp error_message(other), do: to_string(other)

  defp with_encrypted_string_stub(fun) when is_function(fun, 0) do
    {_, original_binary, original_path} = :code.get_object_code(Zaq.Types.EncryptedString)

    :code.purge(Zaq.Types.EncryptedString)
    :code.delete(Zaq.Types.EncryptedString)

    Code.compiler_options(ignore_module_conflict: true)

    Code.compile_string("""
    defmodule Zaq.Types.EncryptedString do
      use Ecto.Type

      def encrypt(_value), do: {:error, :boom}
      def decrypt(value), do: {:ok, value}
      def encrypted?(_value), do: false
      def type, do: :string

      def cast(nil), do: {:ok, nil}
      def cast(value) when is_binary(value), do: {:ok, value}
      def cast(_), do: :error

      def load(value), do: {:ok, value}
      def dump(nil), do: {:ok, nil}
      def dump(value) when is_binary(value), do: {:ok, value}
      def dump(_), do: :error
    end
    """)

    Code.compiler_options(ignore_module_conflict: false)

    try do
      fun.()
    after
      :code.purge(Zaq.Types.EncryptedString)
      :code.delete(Zaq.Types.EncryptedString)

      {:module, Zaq.Types.EncryptedString} =
        :code.load_binary(Zaq.Types.EncryptedString, original_path, original_binary)

      Code.compiler_options(ignore_module_conflict: false)
    end
  end
end
