unless Code.ensure_loaded?(Zaq.Repo.Migrations.RemoveAiAuthKindMetadata) do
  Code.require_file(
    "../../../priv/repo/migrations/20260927150000_remove_ai_auth_kind_metadata.exs",
    __DIR__
  )
end

defmodule Zaq.System.AIProviderCredentialAuthMetadataMigrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Connect
  alias Zaq.Repo.Migrations.RemoveAiAuthKindMetadata
  alias Zaq.System

  @version 20_260_927_150_000
  @migration_opts [log: false, migration_lock: false, skip_table_creation: true]

  test "associated AI rows drop stale mode metadata without changing canonical authentication" do
    assert {:ok, ai} =
             System.create_ai_provider_credential(%{
               name: "Legacy mode cleanup #{Ecto.UUID.generate()}",
               provider: "openai",
               endpoint: "https://example.test/v1",
               auth_kind: "none",
               metadata: %{"project" => "zaq"}
             })

    Repo.query!(
      "UPDATE ai_provider_credentials SET metadata = jsonb_set(metadata, '{auth_kind}', to_jsonb($1::text), true) WHERE id = $2",
      ["api_key", ai.id]
    )

    assert :ok =
             Ecto.Migrator.down(Repo, @version, RemoveAiAuthKindMetadata, @migration_opts)

    assert [[%{"auth_kind" => "none", "project" => "zaq"}]] =
             Repo.query!("SELECT metadata FROM ai_provider_credentials WHERE id = $1", [ai.id]).rows

    assert :ok = Ecto.Migrator.up(Repo, @version, RemoveAiAuthKindMetadata, @migration_opts)

    assert [[%{"project" => "zaq"}]] =
             Repo.query!("SELECT metadata FROM ai_provider_credentials WHERE id = $1", [ai.id]).rows

    assert Connect.get_credential!(ai.connect_credential_id).auth_kind == "none"
    assert System.get_ai_provider_credential!(ai.id).auth_kind == "none"
  end
end
