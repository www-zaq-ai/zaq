defmodule Zaq.Engine.ConnectEncryptionErrorTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Connect

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
end
