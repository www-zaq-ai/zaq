defmodule Zaq.TestSupport.CredentialMutationJob do
  @moduledoc false

  import Ecto.Query

  alias Zaq.Repo

  def capture!(credential_id, mutation)
      when is_integer(credential_id) and is_function(mutation, 0) do
    last_job_id = Repo.one(from job in Oban.Job, select: max(job.id)) || 0
    result = mutation.()

    jobs =
      Repo.all(
        from job in Oban.Job,
          where:
            job.id > ^last_job_id and
              fragment("?->>'credential_id'", job.args) == ^to_string(credential_id),
          order_by: [asc: job.id]
      )

    case jobs do
      [job] -> {result, job}
      other -> raise "expected one credential mutation job, got #{length(other)}"
    end
  end

  def deliver!(%Oban.Job{} = job, queue_prefix) when is_binary(queue_prefix) do
    queue = "#{queue_prefix}-#{Ecto.UUID.generate()}"

    job
    |> Ecto.Changeset.change(
      queue: queue,
      state: "available",
      scheduled_at: DateTime.utc_now()
    )
    |> Repo.update!()

    case Oban.drain_queue(queue: queue, with_scheduled: true) do
      %{success: 1, failure: 0, discard: 0} -> :ok
      result -> raise "credential mutation delivery failed: #{inspect(result)}"
    end

    case Repo.reload!(job) do
      %{state: "completed"} -> :ok
      %{state: state} -> raise "credential mutation job finished in #{inspect(state)}"
    end
  end
end
