defmodule Zaq.Engine.Connect.SessionMaterialContractTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Engine.Connect
  alias Zaq.System.SecretConfig

  property "canonical grants preserve opaque session documents and encrypt them at rest" do
    check all(material <- binary(max_length: 4096), max_runs: 20) do
      document = Jason.encode!(%{version: 1, records: %{session: Base.encode64(material)}})
      saved = save(document)

      assert {:ok, resolved} = Connect.resolve_credential(saved.credential_id, nil)
      assert resolved.authentication == %{api_key: document}

      assert %{"records" => %{"session" => encoded}} =
               Jason.decode!(resolved.authentication.api_key)

      assert Base.decode64!(encoded) == material

      %{rows: [[ciphertext]]} =
        Repo.query!("SELECT api_key FROM connect_grants WHERE id = $1", [
          saved.global_grant.grant_id
        ])

      assert SecretConfig.encrypted?(ciphertext)
      refute ciphertext == document
      assert {:ok, ^document} = SecretConfig.decrypt(ciphertext)
      refute inspect(saved) =~ document
    end
  end

  test "replacement preserves the canonical slot and does not affect another account" do
    first = save(~s({"version":1,"records":{"session":"first"}}))
    second_document = ~s({"version":1,"records":{"session":"second"}})
    second = save(second_document)
    replacement = ~s({"version":1,"records":{"session":"rotated"}})

    assert {:ok, result} =
             Connect.replace_credential_grant(first.credential_id, :org, %{api_key: replacement})

    assert result.grant_id == first.global_grant.grant_id
    assert {:ok, resolved} = Connect.resolve_credential(first.credential_id, nil)
    assert resolved.authentication == %{api_key: replacement}
    assert {:ok, resolved} = Connect.resolve_credential(second.credential_id, nil)
    assert resolved.authentication == %{api_key: second_document}
  end

  test "an enclosing transaction rollback retains the previous session document" do
    document = ~s({"version":1,"records":{"session":"persisted"}})
    saved = save(document)

    assert {:error, :abort_session_update} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        Connect.replace_credential_grant(saved.credential_id, :org, %{
                          api_key: ~s({"version":1,"records":{}})
                        })

               Repo.rollback(:abort_session_update)
             end)

    assert {:ok, resolved} = Connect.resolve_credential(saved.credential_id, nil)
    assert resolved.authentication == %{api_key: document}
  end

  defp save(document) do
    assert {:ok, saved} =
             Connect.save_credential_configuration(
               nil,
               %{
                 name: "session-contract-#{Ecto.UUID.generate()}",
                 provider: "whatsapp",
                 auth_kind: "api_key",
                 personal_credential_policy: :disabled
               },
               {:replace, %{api_key: document}}
             )

    saved
  end
end
