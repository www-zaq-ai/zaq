defmodule Zaq.Engine.History.Strategy do
  @moduledoc """
  Code-defined history policy selection; no configuration-controlled strategy
  switch, DB mutation, mention gating or permissions granted here. The caller
  must validate normalized facts and use the persisted transcript's authorized
  reader for actual access.
  """

  alias Zaq.Engine.History.{Direct, Facts, Replicated, Shared}
  alias Zaq.Permissions.ChannelHistoryResource

  @type target :: %{
          required(:strategy) => String.t(),
          required(:scope_key) => String.t(),
          required(:provider) => String.t(),
          required(:channel_config_id) => pos_integer(),
          required(:owner_person_id) => pos_integer() | nil
        }

  @callback association_targets(Facts.t()) :: [target()]
  @callback resolve_transcripts(Facts.t()) :: [target()]
  @callback access_policy(Facts.t()) :: term()
  @callback context_sources(Facts.t()) :: [atom()]
  @callback membership_lifecycle() :: atom()

  @strategies %{direct: Direct, shared: Shared, replicated: Replicated}

  @doc "Returns per-message transcript targets; never adds historical recipients."
  @spec association_targets(Facts.t()) :: {:ok, [target()]} | {:error, atom()}
  def association_targets(facts), do: dispatch(facts, :association_targets)

  @doc "Resolves only the requesting Person's active history, not all message recipients."
  @spec resolve_transcripts(Facts.t()) :: {:ok, [target()]} | {:error, atom()}
  def resolve_transcripts(facts), do: dispatch(facts, :resolve_transcripts)

  @doc "Describes the grant or recipient ownership needed, not an access decision."
  @spec access_policy(Facts.t()) :: {:ok, term()} | {:error, atom()}
  def access_policy(facts), do: dispatch(facts, :access_policy)

  @doc "Orders context sources without constructing an unbounded query."
  @spec context_sources(Facts.t()) :: {:ok, [atom()]} | {:error, atom()}
  def context_sources(facts), do: dispatch(facts, :context_sources)

  @doc "Names the only membership lifecycle supported by the strategy."
  @spec membership_lifecycle(Facts.t()) :: {:ok, atom()} | {:error, atom()}
  def membership_lifecycle(facts), do: dispatch(facts, :membership_lifecycle)

  @doc "Builds the common grant-driven transcript target after trusted fact validation."
  def grant_target(facts, strategy, thread_id \\ nil) do
    {type, id} =
      ChannelHistoryResource.for(facts.provider, facts.channel_config_id, facts.channel_id)

    %{
      strategy: strategy,
      provider: facts.provider,
      channel_config_id: facts.channel_config_id,
      external_channel_id: facts.channel_id,
      external_thread_id: thread_id,
      parent_id: if(thread_id, do: facts.parent.id, else: nil),
      owner_person_id: nil,
      permission_resource_type: type,
      permission_resource_id: id,
      scope_key: scope_key(facts, strategy, thread_id)
    }
  end

  @doc "Encodes a collision-safe transcript scope by strategy, connector and conversation."
  def scope_key(facts, strategy, suffix),
    do:
      Jason.encode!([strategy, facts.provider, facts.channel_config_id, facts.channel_id, suffix])

  defp dispatch(%Facts{} = facts, callback) do
    with {:ok, validated} <- Facts.new(Map.from_struct(facts)),
         {:ok, kind} <- Facts.strategy(validated) do
      policy = Map.fetch!(@strategies, kind)

      result =
        if callback == :membership_lifecycle,
          do: apply(policy, callback, []),
          else: apply(policy, callback, [validated])

      {:ok, result}
    end
  end

  defp dispatch(_facts, _callback), do: {:error, :invalid_history_facts}
end
