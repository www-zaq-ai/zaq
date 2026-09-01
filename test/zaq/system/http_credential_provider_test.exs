defmodule Zaq.System.HttpCredentialProviderTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Connect
  alias Zaq.System
  alias Zaq.System.HttpCredentialProvider
  alias Zaq.System.HttpCredentialProviderRef

  test "validates and normalizes provider rendering metadata" do
    changeset =
      HttpCredentialProvider.changeset(%HttpCredentialProvider{}, %{
        name: "GitHub API",
        auth_kind: "bearer",
        placement: "header",
        parameter_name: " X-Api-Key ",
        host_patterns: [" API.GitHub.com ", "api.github.com", ".GitHub.com"]
      })

    assert changeset.valid?
    provider = Ecto.Changeset.apply_changes(changeset)
    assert provider.parameter_name == "x-api-key"
    assert provider.host_patterns == ["api.github.com", ".github.com"]
  end

  test "requires parameter names only where placement needs one" do
    assert %{parameter_name: [_]} =
             errors_on(
               HttpCredentialProvider.changeset(%HttpCredentialProvider{}, %{
                 name: "Query Provider",
                 auth_kind: "api_key",
                 placement: "query",
                 host_patterns: ["api.example.com"]
               })
             )

    assert %{parameter_name: [_]} =
             errors_on(
               HttpCredentialProvider.changeset(%HttpCredentialProvider{}, %{
                 name: "Bearer Provider",
                 auth_kind: "bearer",
                 placement: "authorization",
                 parameter_name: "authorization",
                 host_patterns: ["api.example.com"]
               })
             )
  end

  test "clears an existing parameter name for authorization placement" do
    changeset =
      HttpCredentialProvider.changeset(%HttpCredentialProvider{parameter_name: "x-api-key"}, %{
        name: "Bearer Provider",
        auth_kind: "bearer",
        placement: "authorization",
        parameter_name: nil,
        host_patterns: ["api.example.com"]
      })

    assert changeset.valid?
    assert Map.fetch!(changeset.changes, :parameter_name) == nil
    assert Ecto.Changeset.apply_changes(changeset).parameter_name == nil
  end

  test "rejects line breaks in normalized parameter names" do
    for {parameter_name, normalized} <- [
          {"X-Api\rKey", "x-api\rkey"},
          {"X-Api\nKey", "x-api\nkey"},
          {"X-Api\r\nKey", "x-api\r\nkey"}
        ] do
      changeset =
        HttpCredentialProvider.changeset(%HttpCredentialProvider{}, %{
          name: "Custom Provider",
          auth_kind: "custom",
          placement: "header",
          parameter_name: parameter_name,
          host_patterns: ["api.example.com"]
        })

      refute changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :parameter_name) == normalized
      assert errors_on(changeset) == %{parameter_name: ["must not contain line breaks"]}
    end
  end

  test "rejects reserved headers and invalid host patterns" do
    changeset =
      HttpCredentialProvider.changeset(%HttpCredentialProvider{}, %{
        name: "Bad Provider",
        auth_kind: "custom",
        placement: "header",
        parameter_name: "Host",
        host_patterns: ["not a host", "..example.com"]
      })

    assert %{parameter_name: [_], host_patterns: [_]} = errors_on(changeset)
  end

  test "persists providers through the System context" do
    assert {:ok, provider} =
             System.create_http_credential_provider(%{
               name: "Stripe API",
               auth_kind: "bearer",
               placement: "authorization",
               host_patterns: ["api.stripe.com"]
             })

    assert System.get_http_credential_provider!(provider.id).name == "Stripe API"
    assert [%HttpCredentialProvider{id: id}] = System.list_http_credential_providers()
    assert id == provider.id

    assert {:ok, updated} =
             System.update_http_credential_provider(provider, %{enabled: false})

    assert updated.enabled == false
    assert {:ok, _deleted} = System.delete_http_credential_provider(updated)
    assert System.get_http_credential_provider(provider.id) == nil
  end

  test "refuses to delete providers referenced by Auth Credentials" do
    {:ok, provider} =
      System.create_http_credential_provider(%{
        name: "Referenced API",
        auth_kind: "bearer",
        placement: "authorization",
        host_patterns: ["api.example.com"]
      })

    {:ok, provider_ref} = HttpCredentialProviderRef.format(provider.id)

    {:ok, _credential} =
      Connect.create_credential(%{
        name: "Referenced Token",
        provider: provider_ref,
        auth_kind: "api_key",
        request_format: "raw",
        user_level: false,
        metadata: %{},
        api_key: "secret"
      })

    assert {:error, changeset} = System.delete_http_credential_provider(provider)
    assert "is referenced by 1 Auth Credential" in errors_on(changeset).id
    assert %HttpCredentialProvider{} = System.get_http_credential_provider(provider.id)
  end
end
