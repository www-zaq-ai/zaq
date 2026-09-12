defmodule Zaq.Engine.IncomingMessageRoutingRule do
  @moduledoc """
  Persisted incoming-message routing policy.

  Rules describe the scope and destination mode for incoming communication
  messages. Engine routing resolves these rules and translates them into
  executable `%Zaq.Event{}` hops.
  Database-backed policy validation is shared by read-only context changesets
  and persistence-time checks, using the rule's repository prefix.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Zaq.Accounts.Person
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Channels.{ChannelConfig, RetrievalChannel}

  @routing_modes [:agent, :none]
  @type t :: %__MODULE__{}

  schema "incoming_message_routing_rules" do
    belongs_to :person, Person
    belongs_to :channel_config, ChannelConfig
    belongs_to :retrieval_channel, RetrievalChannel
    belongs_to :configured_agent, ConfiguredAgent

    field :topic_id, :string
    field :routing_mode, Ecto.Enum, values: @routing_modes

    timestamps(type: :utc_datetime)
  end

  @fields ~w(person_id channel_config_id retrieval_channel_id configured_agent_id topic_id routing_mode)a

  @doc false
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, @fields)
    |> normalize_topic_id()
    |> normalize_destination()
    |> validate_required([:routing_mode])
    |> validate_destination()
    |> validate_scope()
    |> assoc_constraint(:person)
    |> assoc_constraint(:channel_config)
    |> assoc_constraint(:retrieval_channel)
    |> assoc_constraint(:configured_agent)
    |> prepare_changes(&validate_policy(&1, &1.repo))
    |> unique_constraint(:person_id, name: :incoming_message_routing_rules_one_global_index)
    |> unique_constraint(:channel_config_id,
      name: :incoming_message_routing_rules_one_provider_index
    )
    |> unique_constraint(:retrieval_channel_id,
      name: :incoming_message_routing_rules_one_channel_index
    )
    |> unique_constraint([:channel_config_id, :topic_id],
      name: :incoming_message_routing_rules_one_topic_index
    )
    |> unique_constraint(:person_id,
      name: :incoming_message_routing_rules_one_person_global_index
    )
    |> unique_constraint([:person_id, :channel_config_id],
      name: :incoming_message_routing_rules_one_person_provider_index
    )
    |> unique_constraint([:person_id, :retrieval_channel_id],
      name: :incoming_message_routing_rules_one_person_channel_index
    )
    |> unique_constraint([:person_id, :channel_config_id, :topic_id],
      name: :incoming_message_routing_rules_one_person_topic_index
    )
  end

  defp normalize_topic_id(changeset) do
    case fetch_change(changeset, :topic_id) do
      {:ok, topic_id} when is_binary(topic_id) ->
        case String.trim(topic_id) do
          "" -> put_change(changeset, :topic_id, nil)
          normalized -> put_change(changeset, :topic_id, normalized)
        end

      {:ok, nil} ->
        put_change(changeset, :topic_id, nil)

      {:ok, _topic_id} ->
        add_error(changeset, :topic_id, "must be a string")

      :error ->
        changeset
    end
  end

  defp normalize_destination(changeset) do
    case get_field(changeset, :routing_mode) do
      :none -> put_change(changeset, :configured_agent_id, nil)
      _ -> changeset
    end
  end

  defp validate_destination(changeset) do
    case get_field(changeset, :routing_mode) do
      :agent -> validate_required(changeset, [:configured_agent_id])
      :none -> validate_absent(changeset, :configured_agent_id)
      _ -> changeset
    end
  end

  defp validate_scope(changeset) do
    channel_config_id = get_field(changeset, :channel_config_id)
    retrieval_channel_id = get_field(changeset, :retrieval_channel_id)
    topic_id = get_field(changeset, :topic_id)

    cond do
      retrieval_channel_id && is_nil(channel_config_id) ->
        add_error(changeset, :channel_config_id, "is required for channel rules")

      topic_id && is_nil(channel_config_id) ->
        add_error(changeset, :channel_config_id, "is required for topic rules")

      retrieval_channel_id && topic_id ->
        add_error(changeset, :topic_id, "cannot be set for retrieval channel rules")

      true ->
        changeset
    end
  end

  defp validate_absent(changeset, field) do
    if get_field(changeset, field) do
      add_error(changeset, field, "must be blank")
    else
      changeset
    end
  end

  @doc "Validates current agent eligibility and channel ownership without writing. Persistence rechecks the same policies."
  @spec validate_policy(Ecto.Changeset.t(), module()) :: Ecto.Changeset.t()
  def validate_policy(%{valid?: false} = changeset, _repo), do: changeset

  def validate_policy(changeset, repo) do
    changeset
    |> validate_configured_agent_eligible(repo)
    |> validate_retrieval_channel_belongs_to_config(repo)
  end

  defp validate_configured_agent_eligible(changeset, repo) do
    case {get_field(changeset, :routing_mode), get_field(changeset, :configured_agent_id)} do
      {:agent, agent_id} when not is_nil(agent_id) ->
        exists? =
          repo.exists?(
            from(agent in ConfiguredAgent,
              where:
                agent.id == ^agent_id and agent.active == true and
                  agent.conversation_enabled == true
            ),
            policy_query_opts(changeset)
          )

        if exists? do
          changeset
        else
          add_error(changeset, :configured_agent_id, "must be conversation-enabled")
        end

      _ ->
        changeset
    end
  end

  defp validate_retrieval_channel_belongs_to_config(changeset, repo) do
    channel_config_id = get_field(changeset, :channel_config_id)
    retrieval_channel_id = get_field(changeset, :retrieval_channel_id)

    if channel_config_id && retrieval_channel_id do
      exists? =
        repo.exists?(
          from(channel in RetrievalChannel,
            where:
              channel.id == ^retrieval_channel_id and
                channel.channel_config_id == ^channel_config_id
          ),
          policy_query_opts(changeset)
        )

      if exists? do
        changeset
      else
        add_error(changeset, :retrieval_channel_id, "must belong to channel config")
      end
    else
      changeset
    end
  end

  defp policy_query_opts(changeset) do
    case Keyword.get(changeset.repo_opts, :prefix, Ecto.get_meta(changeset.data, :prefix)) do
      nil -> []
      prefix -> [prefix: prefix]
    end
  end
end
