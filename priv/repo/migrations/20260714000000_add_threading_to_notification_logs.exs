defmodule Zaq.Repo.Migrations.AddThreadingToNotificationLogs do
  use Ecto.Migration

  def change do
    alter table(:notification_logs) do
      # The RFC threading anchor of a *delivered* email: its own Message-ID, the
      # parent it replied to, and the References chain. Written on the sent
      # transition, read back to anchor the next send in the same thread.
      add :threading, :map
      # The grouping key the thread is chained under (topic, else subject).
      add :thread_key, :string
    end

    create index(:notification_logs, [:recipient_ref_type, :recipient_ref_id, :thread_key],
             where: "threading IS NOT NULL",
             name: :notification_logs_thread_anchor_index
           )
  end
end
