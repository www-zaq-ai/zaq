defmodule Zaq.System.AIProviderCredentialTest do
  use Zaq.DataCase, async: false

  import Ecto.Query

  alias Zaq.Engine.Connect
  alias Zaq.Repo
  alias Zaq.System
  alias Zaq.System.AIProviderCredential

  defmodule RuntimeCredentialRouter do
    def dispatch(%Zaq.Event{} = event) do
      send(self(), {:runtime_credential_event, event})
      %{event | response: Process.get(:runtime_credential_response)}
    end
  end

  setup do
    prev_secret = Application.get_env(:zaq, Zaq.System.SecretConfig, [])

    Application.put_env(:zaq, Zaq.System.SecretConfig,
      encryption_key: Base.encode64(:crypto.strong_rand_bytes(32)),
      key_id: "test-v1"
    )

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.System.SecretConfig, prev_secret)
    end)

    :ok
  end

  test "creates, lists, gets and deletes AI provider credentials" do
    unique = :erlang.unique_integer([:positive])

    assert {:ok, %AIProviderCredential{} = credential} =
             System.create_ai_provider_credential(%{
               name: "OpenAI EU #{unique}",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               metadata: %{"auth_kind" => "none"},
               sovereign: true,
               description: "EU sovereign endpoint"
             })

    assert Enum.any?(System.list_ai_provider_credentials(), &(&1.id == credential.id))
    assert %AIProviderCredential{id: id} = System.get_ai_provider_credential!(credential.id)
    assert id == credential.id

    assert {:ok, _} = System.delete_ai_provider_credential(credential)
    refute Enum.any?(System.list_ai_provider_credentials(), &(&1.id == credential.id))
  end

  test "stores metadata for OpenAI Codex OAuth2 configuration" do
    assert {:ok, credential} =
             System.create_ai_provider_credential(%{
               name: "OpenAI Codex Metadata",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               metadata: %{
                 "auth_kind" => "oauth2",
                 "auth_profile" => "openai_chatgpt_codex",
                 "client_id" => "client-id"
               }
             })

    loaded = System.get_ai_provider_credential!(credential.id)
    assert loaded.metadata["auth_kind"] == "oauth2"
    assert loaded.metadata["auth_profile"] == "openai_chatgpt_codex"
  end

  test "create_ai_provider_credential/0 returns an invalid changeset error" do
    assert {:error, %Ecto.Changeset{} = changeset} = System.create_ai_provider_credential()
    assert "can't be blank" in errors_on(changeset).name
    assert "can't be blank" in errors_on(changeset).provider
    assert "can't be blank" in errors_on(changeset).endpoint
  end

  test "change_ai_provider_credential/1 returns a base changeset" do
    changeset = System.change_ai_provider_credential(%AIProviderCredential{})
    assert %Ecto.Changeset{} = changeset
    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).name
  end

  test "stores api_key encrypted in DB and returns decrypted value" do
    assert {:ok, credential} =
             System.create_ai_provider_credential(%{
               name: "Anthropic",
               provider: "anthropic",
               endpoint: "https://api.anthropic.com/v1",
               api_key: "sk-credential-secret"
             })

    [[raw_api_key]] =
      Repo.query!("SELECT api_key FROM ai_provider_credentials WHERE id = $1", [credential.id]).rows

    assert String.starts_with?(raw_api_key, "enc:")

    loaded = System.get_ai_provider_credential!(credential.id)
    assert loaded.api_key == "sk-credential-secret"
  end

  test "returns changeset error when api_key encryption key is invalid" do
    prev = Application.get_env(:zaq, Zaq.System.SecretConfig)

    Application.put_env(:zaq, Zaq.System.SecretConfig,
      encryption_key: "invalid",
      key_id: "test-v1"
    )

    try do
      assert {:error, %Ecto.Changeset{} = changeset} =
               System.create_ai_provider_credential(%{
                 name: "Failing",
                 provider: "openai",
                 endpoint: "https://api.openai.com/v1",
                 api_key: "must-fail"
               })

      assert hd(errors_on(changeset).api_key) =~ "could not be encrypted"
    after
      Application.put_env(:zaq, Zaq.System.SecretConfig, prev)
    end
  end

  test "returns specific changeset error when api_key encryption key is missing" do
    prev = Application.get_env(:zaq, Zaq.System.SecretConfig)
    Application.put_env(:zaq, Zaq.System.SecretConfig, [])

    try do
      assert {:error, %Ecto.Changeset{} = changeset} =
               System.create_ai_provider_credential(%{
                 name: "Failing Missing Key",
                 provider: "openai",
                 endpoint: "https://api.openai.com/v1",
                 api_key: "must-fail"
               })

      assert hd(errors_on(changeset).api_key) =~ "missing SYSTEM_CONFIG_ENCRYPTION_KEY"
    after
      Application.put_env(:zaq, Zaq.System.SecretConfig, prev)
    end
  end

  test "blank api_key update preserves previously stored key" do
    assert {:ok, credential} =
             System.create_ai_provider_credential(%{
               name: "Reusable",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               api_key: "first-secret"
             })

    assert {:ok, _} =
             System.update_ai_provider_credential(credential, %{
               name: "Reusable",
               provider: "openai",
               endpoint: "https://api.openai.com/v2",
               api_key: ""
             })

    loaded = System.get_ai_provider_credential!(credential.id)
    assert loaded.api_key == "first-secret"
    assert loaded.endpoint == "https://api.openai.com/v2"
  end

  test "blank api_key update preserves key for string-key attrs" do
    assert {:ok, credential} =
             System.create_ai_provider_credential(%{
               name: "Reusable String",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               api_key: "first-secret-string"
             })

    assert {:ok, _} =
             System.update_ai_provider_credential(credential, %{
               "name" => "Reusable String",
               "provider" => "openai",
               "endpoint" => "https://api.openai.com/v3",
               "api_key" => ""
             })

    loaded = System.get_ai_provider_credential!(credential.id)
    assert loaded.api_key == "first-secret-string"
    assert loaded.endpoint == "https://api.openai.com/v3"
  end

  test "partial string-key update preserves canonical authentication" do
    assert {:ok, credential} =
             System.create_ai_provider_credential(%{
               name: "Partial String Update",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               api_key: "first-secret"
             })

    assert {:ok, updated} =
             System.update_ai_provider_credential(credential, %{
               "endpoint" => "https://api.openai.com/v4"
             })

    assert updated.endpoint == "https://api.openai.com/v4"
    assert {:ok, resolved} = System.resolve_ai_provider_authentication(updated)
    assert resolved.authentication == %{api_key: "first-secret"}
  end

  test "ordinary edits preserve migrated OAuth configuration absent from AI metadata" do
    assert {:ok, credential} =
             System.create_ai_provider_credential(%{
               name: "Migrated OAuth Edit",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               metadata: %{
                 "auth_kind" => "oauth2",
                 "client_id" => "client-id",
                 "token_url" => "https://provider.example/token"
               }
             })

    migrated = Repo.update!(Ecto.Changeset.change(credential, metadata: %{}))

    assert {:ok, updated} =
             System.update_ai_provider_credential(migrated, %{
               "endpoint" => "https://api.openai.com/v2"
             })

    connect = Connect.get_credential!(updated.connect_credential_id)
    assert connect.auth_kind == "oauth2"
    assert connect.client_id == "client-id"
    assert connect.metadata["token_url"] == "https://provider.example/token"
  end

  test "personal credential policy is stored on Connect and enforces global grant requirements" do
    assert {:ok, required} =
             System.create_ai_provider_credential(%{
               name: "Required BYOK",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               personal_credential_policy: "required"
             })

    required_connect = Connect.get_credential!(required.connect_credential_id)
    assert required_connect.personal_credential_policy == :required
    assert [] == Connect.list_grants(credential_id: required_connect.id)

    assert {:error, %Ecto.Changeset{} = changeset} =
             System.create_ai_provider_credential(%{
               name: "Optional Without Global",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               personal_credential_policy: "optional"
             })

    assert "a usable global credential is required for disabled or optional personal credentials" in errors_on(
             changeset
           ).base

    assert {:ok, optional} =
             System.create_ai_provider_credential(%{
               name: "Optional With Global",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               api_key: "sk-company",
               personal_credential_policy: "optional"
             })

    assert Connect.get_credential!(optional.connect_credential_id).personal_credential_policy ==
             :optional

    assert optional
           |> System.change_ai_provider_credential()
           |> Ecto.Changeset.get_field(:personal_credential_policy) == :optional

    assert {:ok, updated} =
             System.update_ai_provider_credential(optional, %{
               personal_credential_policy: :required,
               api_key: ""
             })

    assert Connect.get_credential!(updated.connect_credential_id).personal_credential_policy ==
             :required
  end

  test "resolve_ai_provider_api_key uses the associated grant and ignores unrelated legacy grants" do
    assert {:ok, ai_credential} =
             System.create_ai_provider_credential(%{
               name: "OpenAI API Key Preferred",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               api_key: "sk-preferred"
             })

    connect_credential = create_connect_token_credential("openai")
    issue_connect_ai_grant(connect_credential, ai_credential, "grant-token")

    assert System.resolve_ai_provider_api_key(
             System.get_ai_provider_credential!(ai_credential.id)
           ) ==
             "sk-preferred"
  end

  test "explicit no-auth removes the canonical grant and resolves empty authentication" do
    assert {:ok, ai_credential} =
             System.create_ai_provider_credential(%{
               name: "OpenAI Explicit No Auth",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               api_key: "sk-before-no-auth"
             })

    assert {:ok, updated} =
             System.update_ai_provider_credential(ai_credential, %{
               metadata: %{"auth_kind" => "none"}
             })

    connect_credential = Connect.get_credential!(updated.connect_credential_id)
    assert connect_credential.auth_kind == "none"
    assert connect_credential.personal_credential_policy == :disabled
    assert connect_credential.secret_binding == :configuration
    assert [] == Connect.list_grants(credential_id: connect_credential.id)

    assert {:ok, resolved} = System.resolve_ai_provider_authentication(updated)
    assert resolved.auth_kind == "none"
    assert resolved.grant_id == nil
    assert resolved.authentication == %{}
    assert System.resolve_ai_provider_api_key(updated) == ""
  end

  test "resolve_ai_provider_api_key does not fall back to legacy resource-bound grants" do
    assert {:ok, ai_credential} =
             System.create_ai_provider_credential(%{
               name: "OpenAI Bearer Fallback",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               metadata: %{"auth_kind" => "oauth2", "client_id" => "client-id"}
             })

    connect_credential = create_connect_token_credential("openai")
    issue_connect_ai_grant(connect_credential, ai_credential, "grant-token")

    assert System.resolve_ai_provider_api_key(
             System.get_ai_provider_credential!(ai_credential.id)
           ) == ""
  end

  test "resolve_ai_provider_api_key returns blank for missing connect grant" do
    assert {:ok, ai_credential} =
             System.create_ai_provider_credential(%{
               name: "OpenAI Missing Grant",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               metadata: %{"auth_kind" => "oauth2", "client_id" => "client-id"}
             })

    assert System.resolve_ai_provider_api_key(
             System.get_ai_provider_credential!(ai_credential.id)
           ) == ""
  end

  test "resolve_ai_provider_api_key returns blank string for nil credential" do
    assert System.resolve_ai_provider_api_key(nil) == ""
  end

  test "resolve_ai_provider_api_key returns the canonical OAuth access token" do
    assert {:ok, credential} =
             System.create_ai_provider_credential(%{
               name: "Canonical OAuth #{Ecto.UUID.generate()}",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               metadata: %{"auth_kind" => "oauth2", "client_id" => "client-id"}
             })

    assert {:ok, _grant} =
             Connect.replace_credential_grant(credential.connect_credential_id, :org, %{
               access_token: "canonical-oauth-access",
               refresh_token: "canonical-oauth-refresh",
               expires_at: ~U[2099-01-01 00:00:00Z]
             })

    loaded = System.get_ai_provider_credential!(credential.id)
    assert System.resolve_ai_provider_api_key(loaded) == "canonical-oauth-access"
    refute System.resolve_ai_provider_api_key(loaded) == "canonical-oauth-refresh"
  end

  test "form changeset preserves policy when the Connect association is unavailable" do
    assert {:error, :not_found} = Connect.fetch_credential(-1)

    input = %AIProviderCredential{
      name: "Missing association",
      provider: "openai",
      endpoint: "https://api.openai.com/v1",
      connect_credential_id: -1,
      personal_credential_policy: :required
    }

    changeset =
      System.change_ai_provider_credential(input, %{description: "editable description"})

    assert changeset.data == input
    assert Ecto.Changeset.get_field(changeset, :personal_credential_policy) == :required
    assert Ecto.Changeset.get_field(changeset, :connect_credential_id) == -1
    assert Ecto.Changeset.get_change(changeset, :description) == "editable description"
  end

  test "create uniqueness failure rolls back its Connect definition" do
    original_name = "Rollback create #{Ecto.UUID.generate()}"
    target_name = "Rollback target #{Ecto.UUID.generate()}"

    assert {:ok, original} = create_no_auth(original_name)
    assert {:ok, renamed} = System.update_ai_provider_credential(original, %{name: target_name})
    assert Connect.get_credential!(renamed.connect_credential_id).name == "AI: #{original_name}"
    jobs_before = notification_job_ids()

    assert {:error, %Ecto.Changeset{} = changeset} = create_no_auth(target_name)
    assert errors_on(changeset).name == ["has already been taken"]
    assert Repo.get_by(AIProviderCredential, name: target_name).id == renamed.id
    refute Repo.get_by(Connect.Credential, name: "AI: #{target_name}")
    assert notification_job_ids() == jobs_before
  end

  test "update uniqueness failure rolls back preceding Connect changes" do
    assert {:ok, first} = create_no_auth("Rollback first #{Ecto.UUID.generate()}")
    assert {:ok, second} = create_no_auth("Rollback second #{Ecto.UUID.generate()}")
    original_connect = Connect.get_credential!(second.connect_credential_id)
    jobs_before = notification_job_ids()

    assert {:error, %Ecto.Changeset{} = changeset} =
             System.update_ai_provider_credential(second, %{
               name: first.name,
               provider: "anthropic",
               endpoint: "https://api.anthropic.com/v1"
             })

    assert errors_on(changeset).name == ["has already been taken"]
    restored = Repo.get!(AIProviderCredential, second.id)
    restored_connect = Connect.get_credential!(second.connect_credential_id)
    assert restored.name == second.name
    assert restored.provider == second.provider
    assert restored.endpoint == second.endpoint
    assert restored.connect_credential_id == second.connect_credential_id
    assert restored_connect.provider == original_connect.provider
    assert restored_connect.name == original_connect.name
    assert Repo.get!(AIProviderCredential, first.id).name == first.name
    assert notification_job_ids() == jobs_before
  end

  test "optional policy transition without a global credential is atomic" do
    assert {:ok, credential} =
             System.create_ai_provider_credential(%{
               name: "Required transition #{Ecto.UUID.generate()}",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               personal_credential_policy: :required
             })

    connect = Connect.get_credential!(credential.connect_credential_id)
    assert connect.personal_credential_policy == :required
    assert Connect.list_grants(credential_id: connect.id) == []
    jobs_before = notification_job_ids()

    assert {:error, %Ecto.Changeset{} = changeset} =
             System.update_ai_provider_credential(credential, %{
               personal_credential_policy: :optional,
               description: "must roll back"
             })

    assert "a usable global credential is required for disabled or optional personal credentials" in errors_on(
             changeset
           ).base

    restored = Repo.get!(AIProviderCredential, credential.id)
    restored_connect = Connect.get_credential!(credential.connect_credential_id)
    assert restored_connect.personal_credential_policy == :required
    assert restored.description == credential.description
    assert restored.connect_credential_id == credential.connect_credential_id
    assert Connect.list_grants(credential_id: connect.id) == []
    assert notification_job_ids() == jobs_before
  end

  test "legacy API key encryption failure rolls back a valid OAuth create" do
    name = "Legacy key failure #{Ecto.UUID.generate()}"
    jobs_before = notification_job_ids()

    with_missing_encryption_key(fn ->
      assert {:error, changeset} =
               System.create_ai_provider_credential(%{
                 name: name,
                 provider: "openai",
                 endpoint: "https://api.openai.com/v1",
                 api_key: "legacy-key-must-not-persist",
                 metadata: %{"auth_kind" => "oauth2", "client_id" => "client-id"},
                 personal_credential_policy: :required
               })

      assert errors_on(changeset).api_key ==
               ["could not be encrypted: missing SYSTEM_CONFIG_ENCRYPTION_KEY"]

      refute Map.has_key?(changeset.changes, :api_key)
    end)

    refute Repo.get_by(AIProviderCredential, name: name)
    refute Repo.get_by(Connect.Credential, name: "AI: #{name}")
    assert notification_job_ids() == jobs_before
  end

  test "legacy API key encryption failure rolls back a valid OAuth update" do
    name = "Legacy update failure #{Ecto.UUID.generate()}"

    assert {:ok, credential} =
             System.create_ai_provider_credential(%{
               name: name,
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               metadata: %{"auth_kind" => "oauth2", "client_id" => "client-id"},
               personal_credential_policy: :required
             })

    original_connect = Connect.get_credential!(credential.connect_credential_id)

    original_connect_projection =
      Map.take(original_connect, [:name, :provider, :auth_kind, :client_id, :metadata])

    jobs_before = notification_job_ids()

    with_missing_encryption_key(fn ->
      assert {:error, changeset} =
               System.update_ai_provider_credential(credential, %{
                 endpoint: "https://api.openai.com/v2",
                 api_key: "legacy-update-must-not-persist",
                 metadata: %{"auth_kind" => "oauth2", "client_id" => "client-id"}
               })

      assert errors_on(changeset).api_key ==
               ["could not be encrypted: missing SYSTEM_CONFIG_ENCRYPTION_KEY"]

      refute Map.has_key?(changeset.changes, :api_key)
    end)

    restored = Repo.get!(AIProviderCredential, credential.id)
    assert restored.endpoint == credential.endpoint
    assert restored.api_key == credential.api_key
    assert restored.connect_credential_id == credential.connect_credential_id
    restored_connect = Connect.get_credential!(credential.connect_credential_id)

    assert Map.take(restored_connect, [:name, :provider, :auth_kind, :client_id, :metadata]) ==
             original_connect_projection

    assert notification_job_ids() == jobs_before
  end

  test "OAuth client-secret encryption failure maps to the generic AI key error" do
    name = "OAuth secret failure #{Ecto.UUID.generate()}"
    jobs_before = notification_job_ids()

    with_missing_encryption_key(fn ->
      assert {:error, changeset} =
               System.create_ai_provider_credential(%{
                 name: name,
                 provider: "openai",
                 endpoint: "https://api.openai.com/v1",
                 metadata: %{
                   "auth_kind" => "oauth2",
                   "client_id" => "client-id",
                   "client_secret" => "client-secret-must-not-persist"
                 }
               })

      assert errors_on(changeset).api_key == ["could not be encrypted"]
    end)

    refute Repo.get_by(AIProviderCredential, name: name)
    refute Repo.get_by(Connect.Credential, name: "AI: #{name}")
    assert notification_job_ids() == jobs_before
  end

  test "invalid OAuth configuration maps to a fixed base error" do
    name = "Invalid OAuth #{Ecto.UUID.generate()}"
    jobs_before = notification_job_ids()

    assert {:error, changeset} =
             System.create_ai_provider_credential(%{
               name: name,
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               metadata: %{"auth_kind" => "oauth2"}
             })

    {base_error, metadata} = changeset.errors[:base]
    assert base_error == "authentication configuration is invalid"
    assert metadata[:reason] == :invalid_configuration
    refute Repo.get_by(AIProviderCredential, name: name)
    refute Repo.get_by(Connect.Credential, name: "AI: #{name}")
    assert notification_job_ids() == jobs_before
  end

  test "global authentication resolution uses the confidential Engine boundary" do
    credential = %AIProviderCredential{id: 42, connect_credential_id: 84}

    resolved = %Zaq.Engine.Connect.ResolvedCredential{
      credential_id: 84,
      grant_id: 126,
      owner_type: "org",
      owner_id: nil,
      auth_kind: "api_key",
      request_format: "bearer",
      authentication: %{api_key: "boundary-secret"}
    }

    Process.put(
      :runtime_credential_response,
      {:ok, %{credential: %{id: 42}, resolved_credential: resolved}}
    )

    on_exit(fn -> Process.delete(:runtime_credential_response) end)

    assert System.resolve_ai_provider_authentication(credential,
             node_router_module: RuntimeCredentialRouter
           ) == {:ok, resolved}

    assert_received {:runtime_credential_event, event}
    assert event.request == %{credential_id: 42}
    assert event.next_hop.destination == :engine
    assert event.actor == %{kind: :system, subject: "system-ai-runtime"}
    assert event.opts[:action] == :resolve_ai_runtime_credential
    assert event.opts[:confidential] == true
  end

  test "global authentication resolution propagates Engine unavailability" do
    credential = %AIProviderCredential{id: 42, connect_credential_id: 84}
    Process.put(:runtime_credential_response, {:error, {:service_unavailable, :engine}})
    on_exit(fn -> Process.delete(:runtime_credential_response) end)

    assert System.resolve_ai_provider_authentication(credential,
             node_router_module: RuntimeCredentialRouter
           ) == {:error, {:service_unavailable, :engine}}
  end

  test "cannot delete credential currently used by system configuration" do
    assert {:ok, credential} =
             System.create_ai_provider_credential(%{
               name: "In Use Credential",
               provider: "openai",
               endpoint: "https://api.openai.com/v1",
               metadata: %{"auth_kind" => "none"}
             })

    System.set_config("llm.credential_id", credential.id)

    assert {:error, %Ecto.Changeset{} = changeset} =
             System.delete_ai_provider_credential(credential)

    assert "cannot delete credential currently used by system configuration" in errors_on(
             changeset
           ).base

    id = credential.id
    assert %AIProviderCredential{id: ^id} = System.get_ai_provider_credential!(id)
  end

  defp create_connect_token_credential(provider) do
    unique = :erlang.unique_integer([:positive])

    {:ok, credential} =
      Connect.create_credential(%{
        name: "#{provider} Connect #{unique}",
        provider: provider,
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{"auth_profile" => "openai_chatgpt_codex"},
        client_id: "client-id"
      })

    credential
  end

  defp issue_connect_ai_grant(connect_credential, ai_credential, token) do
    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: connect_credential.id,
        resource_type: "ai_provider_credential",
        resource_id: ai_credential.id,
        owner_type: "org",
        metadata: %{},
        access_token: token,
        refresh_token: "refresh-token",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    grant
  end

  defp create_no_auth(name) do
    System.create_ai_provider_credential(%{
      name: name,
      provider: "openai",
      endpoint: "https://api.openai.com/v1",
      metadata: %{"auth_kind" => "none"}
    })
  end

  defp notification_job_ids do
    Repo.all(
      from job in Oban.Job,
        where: job.queue == "connect_credential_notifications",
        select: job.id,
        order_by: job.id
    )
  end

  defp with_missing_encryption_key(fun) do
    previous = Application.fetch_env(:zaq, Zaq.System.SecretConfig)
    Application.put_env(:zaq, Zaq.System.SecretConfig, key_id: "test-v1", encryption_key: nil)

    try do
      fun.()
    after
      case previous do
        {:ok, value} -> Application.put_env(:zaq, Zaq.System.SecretConfig, value)
        :error -> Application.delete_env(:zaq, Zaq.System.SecretConfig)
      end
    end
  end
end
