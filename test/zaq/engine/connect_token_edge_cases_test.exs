defmodule Zaq.Engine.ConnectTokenEdgeCasesTest do
  @moduledoc "Tests token update and persistence edge cases across Connect auth kinds."

  use Zaq.DataCase, async: false

  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant}
  alias Zaq.Repo

  defmodule StubOAuthMissingAccessToken do
    def oauth_refresh_token(_config, _params) do
      {:ok,
       %{
         access_token: nil,
         refresh_token: "r2",
         expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
       }}
    end
  end

  setup do
    original_secret = Application.get_env(:zaq, Zaq.System.SecretConfig)

    Application.put_env(:zaq, Zaq.System.SecretConfig,
      encryption_key: Base.encode64(:crypto.strong_rand_bytes(32)),
      key_id: "v1"
    )

    on_exit(fn ->
      if original_secret do
        Application.put_env(:zaq, Zaq.System.SecretConfig, original_secret)
      else
        Application.delete_env(:zaq, Zaq.System.SecretConfig)
      end
    end)

    :ok
  end

  defp create_oauth_credential do
    {:ok, credential} =
      Connect.create_credential(%{
        name: "OAuth 2 Config",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{"authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth"},
        client_id: "client-id",
        client_secret: "secret"
      })

    credential
  end

  defp create_jwt_credential(metadata \\ %{"auth_profile_id" => "service_account"}) do
    {:ok, credential} =
      Connect.create_credential(%{
        name: "JWT Config",
        provider: "google_drive",
        auth_kind: "jwt_bearer",
        request_format: "bearer",
        user_level: false,
        metadata: metadata,
        issuer: "svc@example.iam.gserviceaccount.com",
        private_key: "private-key",
        key_id: "kid-1",
        scopes: [
          "https://www.googleapis.com/auth/drive.readonly",
          "https://www.googleapis.com/auth/drive.metadata.readonly"
        ]
      })

    credential
  end

  defp issue_oauth_grant(credential, overrides \\ []) do
    base = %{
      credential_id: credential.id,
      resource_type: "data_source",
      resource_id: "99",
      owner_type: "org",
      metadata: %{},
      access_token: "tok",
      refresh_token: "ref"
    }

    {:ok, grant} = Connect.issue_grant(Map.merge(base, Map.new(overrides)))
    grant
  end

  defp with_node_router_stub(response_source, fun) when is_binary(response_source) do
    {_, original_binary, original_path} = :code.get_object_code(Zaq.NodeRouter)

    :code.purge(Zaq.NodeRouter)
    :code.delete(Zaq.NodeRouter)

    Code.compiler_options(ignore_module_conflict: true)

    source =
      IO.iodata_to_binary([
        "defmodule Zaq.NodeRouter do\n",
        "  def dispatch(event) do\n",
        "    %{event | response: ",
        response_source,
        "}\n",
        "  end\n",
        "end\n"
      ])

    Code.compile_string(source)

    Code.compiler_options(ignore_module_conflict: false)

    try do
      fun.()
    after
      :code.purge(Zaq.NodeRouter)
      :code.delete(Zaq.NodeRouter)

      {:module, Zaq.NodeRouter} =
        :code.load_binary(Zaq.NodeRouter, original_path, original_binary)

      Code.compiler_options(ignore_module_conflict: false)
    end
  end

  describe "token cache updates" do
    test "refresh_grant returns a changeset error when encrypted token persistence fails" do
      credential = create_oauth_credential()
      grant = issue_oauth_grant(credential)

      original_secret = Application.get_env(:zaq, Zaq.System.SecretConfig)

      Application.put_env(:zaq, Zaq.System.SecretConfig,
        encryption_key: "invalid",
        key_id: "v1"
      )

      on_exit(fn ->
        if original_secret do
          Application.put_env(:zaq, Zaq.System.SecretConfig, original_secret)
        else
          Application.delete_env(:zaq, Zaq.System.SecretConfig)
        end
      end)

      with_node_router_stub(
        ~s|{:ok, %{access_token: "new-access", refresh_token: "new-refresh", expires_at: DateTime.add(DateTime.utc_now(), 3600, :second), scopes: []}}|,
        fn ->
          assert {:error, %Ecto.Changeset{} = changeset} = Connect.refresh_grant(grant)
          assert hd(errors_on(changeset).access_token) =~ "invalid SYSTEM_CONFIG_ENCRYPTION_KEY"
        end
      )
    end

    test "refresh_grant returns missing access token when oauth bridge payload omits it" do
      credential = create_oauth_credential()
      grant = issue_oauth_grant(credential)

      with_node_router_stub(
        "Zaq.Engine.ConnectTokenEdgeCasesTest.StubOAuthMissingAccessToken.oauth_refresh_token(nil, nil)",
        fn ->
          assert {:error, {:invalid_token_payload, :missing_access_token}} =
                   Connect.refresh_grant(grant)
        end
      )
    end

    test "update_grant_token_cache rejects oauth2 payloads with a missing access token" do
      credential = create_oauth_credential()
      grant = issue_oauth_grant(credential)

      assert {:error, {:invalid_token_payload, :missing_access_token}} =
               Connect.update_grant_token_cache(grant, %{
                 access_token: nil,
                 refresh_token: "new-refresh",
                 expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
                 scopes: []
               })
    end

    test "update_grant_token_cache rejects jwt_bearer payloads with a blank access token" do
      credential = create_jwt_credential()

      assert {:ok, grant} =
               Connect.issue_grant(%{
                 credential_id: credential.id,
                 resource_type: "data_source",
                 resource_id: "42",
                 owner_type: "org",
                 metadata: %{"auth_profile_id" => "service_account"},
                 scopes: credential.scopes
               })

      assert {:error, {:invalid_token_payload, :missing_access_token}} =
               Connect.update_grant_token_cache(grant, %{
                 access_token: "",
                 expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
               })
    end

    test "update_grant_token_cache rejects unsupported auth kinds" do
      {:ok, credential} =
        Connect.create_credential(%{
          name: "API Key Config",
          provider: "google_drive",
          auth_kind: "api_key",
          request_format: "raw",
          user_level: false,
          metadata: %{},
          api_key: "shared-token"
        })

      assert {:ok, grant} =
               Connect.issue_grant(%{
                 credential_id: credential.id,
                 resource_type: "data_source",
                 resource_id: "42",
                 owner_type: "org",
                 metadata: %{},
                 api_key: "shared-token"
               })

      assert {:error, {:invalid_token_payload, :unsupported_auth_kind}} =
               Connect.update_grant_token_cache(grant, %{
                 access_token: "ignored",
                 expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
               })
    end

    test "issue_grant falls back to credential scopes when attrs scopes are empty" do
      credential = create_jwt_credential()

      assert {:ok, %Grant{} = grant} =
               Connect.issue_grant(%{
                 credential_id: credential.id,
                 resource_type: "data_source",
                 resource_id: "43",
                 owner_type: "org",
                 metadata: %{"auth_profile_id" => "service_account"},
                 scopes: []
               })

      grant = Repo.get!(Grant, grant.id)
      assert grant.scopes == credential.scopes
    end

    test "issue_grant copies blank jwt fields from the credential" do
      credential =
        create_jwt_credential(%{
          "auth_profile_id" => "service_account",
          "subject" => "svc-subject"
        })

      credential = Repo.get!(Credential, credential.id)

      assert {:ok, %Grant{} = grant} =
               Connect.issue_grant(%{
                 credential_id: credential.id,
                 resource_type: "data_source",
                 resource_id: "44",
                 owner_type: "org",
                 metadata: %{"auth_profile_id" => "service_account"},
                 issuer: "",
                 private_key: "",
                 key_id: "",
                 subject: ""
               })

      grant = Repo.get!(Grant, grant.id)
      assert grant.issuer == credential.issuer
      assert grant.private_key == credential.private_key
      assert grant.key_id == credential.key_id
      assert grant.subject == "svc-subject"
    end

    test "issue_grant tolerates a nil metadata subject" do
      credential = create_jwt_credential()

      assert {:ok, %Grant{} = grant} =
               Connect.issue_grant(%{
                 credential_id: credential.id,
                 resource_type: "data_source",
                 resource_id: "45",
                 owner_type: "org",
                 metadata: %{"auth_profile_id" => "service_account"}
               })

      grant = Repo.get!(Grant, grant.id)
      assert grant.subject == nil
    end

    test "create_credential stores a blank secret without encrypting it" do
      assert {:ok, credential} =
               Connect.create_credential(%{
                 name: "Blank secret storage",
                 provider: "google_drive",
                 auth_kind: "oauth2",
                 request_format: "bearer",
                 user_level: false,
                 metadata: %{},
                 client_id: "client-id",
                 client_secret: ""
               })

      assert Repo.get!(Credential, credential.id).client_secret == nil
    end

    test "update_grant_token_cache returns a validation error for non-binary access tokens" do
      credential = create_oauth_credential()
      grant = issue_oauth_grant(credential)

      assert {:error, changeset} =
               Connect.update_grant_token_cache(grant, %{
                 access_token: 123,
                 refresh_token: "new-refresh",
                 expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
               })

      refute Enum.any?(changeset.errors, fn {_field, {message, _opts}} ->
               message == "could not be encrypted"
             end)
    end
  end
end
