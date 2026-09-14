defmodule Zaq.Engine.Connect.CanonicalEncryptionTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant}

  setup do
    original = Application.get_env(:zaq, Zaq.System.SecretConfig)
    on_exit(fn -> Application.put_env(:zaq, Zaq.System.SecretConfig, original) end)
    :ok
  end

  test "canonical secret writes fail closed with missing or invalid encryption configuration" do
    config = %Credential{id: 1, provider: "example", auth_kind: "api_key"}

    for {key, message} <- [{nil, "missing"}, {"invalid", "invalid"}] do
      Application.put_env(:zaq, Zaq.System.SecretConfig, encryption_key: key, key_id: "test")

      changeset =
        Connect.change_credential_grant(%Grant{}, config, %{
          owner_type: "org",
          api_key: "never-persist-plaintext"
        })

      assert {:error, rejected} = Repo.insert(changeset)

      assert "could not be encrypted: #{message} SYSTEM_CONFIG_ENCRYPTION_KEY" in errors_on(
               rejected
             ).api_key
    end
  end
end
