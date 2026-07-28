defmodule Zaq.Repo.Migrations.CreateIncomingMessageRoutingRules do
  use Ecto.Migration

  def change do
    create table(:incoming_message_routing_rules) do
      add :person_id, references(:people, on_delete: :delete_all)
      add :channel_config_id, references(:channel_configs, on_delete: :delete_all)
      add :retrieval_channel_id, references(:retrieval_channels, on_delete: :delete_all)

      add :configured_agent_id,
          references(:configured_agents, on_delete: :restrict, type: :bigint)

      add :topic_id, :string
      add :routing_mode, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:incoming_message_routing_rules, [:person_id])
    create index(:incoming_message_routing_rules, [:channel_config_id])
    create index(:incoming_message_routing_rules, [:retrieval_channel_id])
    create index(:incoming_message_routing_rules, [:configured_agent_id])
    create index(:incoming_message_routing_rules, [:person_id, :channel_config_id])
    create index(:incoming_message_routing_rules, [:person_id, :retrieval_channel_id])
    create index(:incoming_message_routing_rules, [:channel_config_id, :topic_id])

    create constraint(:incoming_message_routing_rules, :routing_mode_valid,
             check: "routing_mode IN ('agent', 'none')"
           )

    create unique_index(:incoming_message_routing_rules, ["(true)"],
             name: :incoming_message_routing_rules_one_global_index,
             where:
               "person_id IS NULL AND channel_config_id IS NULL AND retrieval_channel_id IS NULL AND topic_id IS NULL"
           )

    create unique_index(:incoming_message_routing_rules, [:channel_config_id],
             name: :incoming_message_routing_rules_one_provider_index,
             where:
               "person_id IS NULL AND channel_config_id IS NOT NULL AND retrieval_channel_id IS NULL AND topic_id IS NULL"
           )

    create unique_index(:incoming_message_routing_rules, [:retrieval_channel_id],
             name: :incoming_message_routing_rules_one_channel_index,
             where: "person_id IS NULL AND retrieval_channel_id IS NOT NULL AND topic_id IS NULL"
           )

    create unique_index(:incoming_message_routing_rules, [:channel_config_id, :topic_id],
             name: :incoming_message_routing_rules_one_topic_index,
             where:
               "person_id IS NULL AND channel_config_id IS NOT NULL AND retrieval_channel_id IS NULL AND topic_id IS NOT NULL"
           )

    create unique_index(:incoming_message_routing_rules, [:person_id],
             name: :incoming_message_routing_rules_one_person_global_index,
             where:
               "person_id IS NOT NULL AND channel_config_id IS NULL AND retrieval_channel_id IS NULL AND topic_id IS NULL"
           )

    create unique_index(:incoming_message_routing_rules, [:person_id, :channel_config_id],
             name: :incoming_message_routing_rules_one_person_provider_index,
             where:
               "person_id IS NOT NULL AND channel_config_id IS NOT NULL AND retrieval_channel_id IS NULL AND topic_id IS NULL"
           )

    create unique_index(:incoming_message_routing_rules, [:person_id, :retrieval_channel_id],
             name: :incoming_message_routing_rules_one_person_channel_index,
             where:
               "person_id IS NOT NULL AND retrieval_channel_id IS NOT NULL AND topic_id IS NULL"
           )

    create unique_index(
             :incoming_message_routing_rules,
             [:person_id, :channel_config_id, :topic_id],
             name: :incoming_message_routing_rules_one_person_topic_index,
             where:
               "person_id IS NOT NULL AND channel_config_id IS NOT NULL AND retrieval_channel_id IS NULL AND topic_id IS NOT NULL"
           )
  end
end
