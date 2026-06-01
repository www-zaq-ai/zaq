defmodule Zaq.Engine.Connect.CredentialTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Connect.Credential

  defp valid_jwt_bearer_attrs(overrides) do
    %{
      name: "Drive SA",
      provider: "google_drive",
      auth_kind: "jwt_bearer",
      request_format: "bearer",
      user_level: false,
      issuer: "svc@example.iam.gserviceaccount.com",
      private_key: "-----BEGIN PRIVATE KEY-----x",
      key_id: "kid-1"
    }
    |> Map.merge(overrides)
  end

  test "requires jwt_bearer fields" do
    changeset =
      Credential.changeset(%Credential{}, %{
        name: "Drive SA",
        provider: "google_drive",
        auth_kind: "jwt_bearer",
        request_format: "bearer",
        user_level: false,
        metadata: %{"auth_profile_id" => "service_account"}
      })

    refute changeset.valid?
    errors = errors_on(changeset)
    assert "can't be blank" in errors.issuer
    assert "can't be blank" in errors.private_key
    assert "can't be blank" in errors.key_id
  end

  test "requires metadata subject for domain delegated jwt profile" do
    changeset =
      Credential.changeset(
        %Credential{},
        valid_jwt_bearer_attrs(%{
          name: "Drive DWD",
          metadata: %{"auth_profile_id" => "domain_delegated_service_account"}
        })
      )

    refute changeset.valid?

    assert "subject is required for domain_delegated_service_account" in errors_on(changeset).metadata
  end

  test "accepts jwt_bearer service_account profile" do
    changeset =
      Credential.changeset(
        %Credential{},
        valid_jwt_bearer_attrs(%{metadata: %{"auth_profile_id" => "service_account"}})
      )

    assert changeset.valid?
  end

  test "rejects jwt_bearer metadata auth_profile_id outside allowed values" do
    changeset =
      Credential.changeset(
        %Credential{},
        valid_jwt_bearer_attrs(%{metadata: %{"auth_profile_id" => "invalid_profile"}})
      )

    refute changeset.valid?

    errors = errors_on(changeset)

    assert "auth_profile_id must be service_account or domain_delegated_service_account" in errors.metadata

    assert Map.get(errors, :issuer, []) == []
    assert Map.get(errors, :private_key, []) == []
    assert Map.get(errors, :key_id, []) == []
  end

  test "accepts domain_delegated_service_account when metadata subject is present" do
    changeset =
      Credential.changeset(
        %Credential{},
        valid_jwt_bearer_attrs(%{
          name: "Drive DWD",
          metadata: %{
            "auth_profile_id" => "domain_delegated_service_account",
            "subject" => "admin@example.com"
          }
        })
      )

    assert changeset.valid?
    assert errors_on(changeset) == %{}
  end

  test "accepts domain_delegated_service_account when metadata subject has whitespace" do
    changeset =
      Credential.changeset(
        %Credential{},
        valid_jwt_bearer_attrs(%{
          name: "Drive DWD",
          metadata: %{
            "auth_profile_id" => "domain_delegated_service_account",
            "subject" => "  admin@example.com  "
          }
        })
      )

    assert changeset.valid?
  end
end
