defmodule Zaq.System.AIProviderCredentialTransactionTest do
  # Transaction-local DDL forces an actual Oban insertion error. Serialize because
  # PostgreSQL takes a table lock; sandbox rollback removes the test constraint.
  use Zaq.DataCase, async: false

  import Ecto.Query

  alias Zaq.Engine.Connect
  alias Zaq.Repo
  alias Zaq.System
  alias Zaq.System.AIProviderCredential
  alias Zaq.SystemConfigFixtures

  defp reject_jobs do
    Repo.query!(
      "ALTER TABLE oban_jobs ADD CONSTRAINT system_ai_delete_event_failure CHECK (queue <> 'connect_credential_notifications') NOT VALID"
    )
  end

  defp notification_job_ids do
    Repo.all(
      from job in Oban.Job,
        where: job.queue == "connect_credential_notifications",
        select: job.id,
        order_by: job.id
    )
  end

  test "Connect delete enqueue failure restores the AI and Connect pair" do
    ai =
      SystemConfigFixtures.ai_credential_fixture(%{
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        metadata: %{"auth_kind" => "none"}
      })

    connect = Connect.get_credential!(ai.connect_credential_id)
    assert Repo.get!(AIProviderCredential, ai.id).connect_credential_id == connect.id
    assert System.get_config("llm.credential_id") != Integer.to_string(ai.id)
    assert System.get_config("embedding.credential_id") != Integer.to_string(ai.id)
    assert System.get_config("image_to_text.credential_id") != Integer.to_string(ai.id)
    jobs_before = notification_job_ids()

    reject_jobs()

    assert {:error, :mutation_event_enqueue_failed} = System.delete_ai_provider_credential(ai)

    restored_ai = Repo.get!(AIProviderCredential, ai.id)
    restored_connect = Connect.get_credential!(connect.id)
    assert restored_ai.id == ai.id
    assert restored_ai.connect_credential_id == connect.id
    assert restored_ai.name == ai.name
    assert restored_ai.provider == ai.provider
    assert restored_ai.endpoint == ai.endpoint
    assert restored_connect.id == connect.id
    assert restored_connect.name == connect.name
    assert restored_connect.provider == connect.provider
    assert notification_job_ids() == jobs_before
  end
end
