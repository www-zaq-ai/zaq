defmodule Zaq.Engine.History.Facts do
  @moduledoc """
  Normalized, internally trusted facts for selecting a communication-history policy.

  Channels must attest connector and per-message recipient evidence before
  constructing these facts; an external Event or Incoming metadata map is not
  proof of identity, delivery, or membership. This struct is pure policy input,
  not a persistence or authorization credential.
  """

  alias Zaq.Engine.Conversations.Transcript
  alias Zaq.Permissions.ChannelHistoryResource

  @type kind :: :direct | :channel | :email
  @type t :: %__MODULE__{
          provider: String.t() | nil,
          channel_config_id: pos_integer() | nil,
          channel_id: String.t() | nil,
          kind: kind() | nil,
          actor_person_id: pos_integer() | nil,
          recipient_person_ids: [pos_integer()],
          thread_id: String.t() | nil,
          parent: %Transcript{} | nil
        }

  defstruct [
    :provider,
    :channel_config_id,
    :channel_id,
    :kind,
    :actor_person_id,
    :thread_id,
    :parent,
    recipient_person_ids: []
  ]

  @shared_providers ~w(mattermost slack discord teams telegram)

  @doc "Builds a validated policy snapshot; does not authenticate its caller."
  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) do
    fields = [
      :provider,
      :channel_config_id,
      :channel_id,
      :kind,
      :actor_person_id,
      :recipient_person_ids,
      :thread_id,
      :parent
    ]

    facts = struct(__MODULE__, Map.take(attrs, fields))

    with :ok <- validate_identity(facts),
         {:ok, strategy} <- strategy(facts),
         :ok <- validate_parent(facts, strategy) do
      {:ok, facts}
    end
  end

  def new(_attrs), do: {:error, :invalid_history_facts}

  @doc "Selects the code-defined strategy, never guessing from a missing channel kind."
  @spec strategy(t()) :: {:ok, :direct | :shared | :replicated} | {:error, :unsupported_strategy}
  def strategy(%__MODULE__{provider: provider, kind: kind})
      when provider in @shared_providers and kind == :direct,
      do: {:ok, :direct}

  def strategy(%__MODULE__{provider: provider, kind: kind})
      when provider in @shared_providers and kind == :channel,
      do: {:ok, :shared}

  def strategy(%__MODULE__{provider: "email:imap", kind: :email}), do: {:ok, :replicated}
  def strategy(%__MODULE__{}), do: {:error, :unsupported_strategy}

  defp validate_identity(facts) do
    valid_recipients? =
      is_list(facts.recipient_person_ids) and
        Enum.all?(facts.recipient_person_ids, &positive_id?/1)

    if positive_id?(facts.channel_config_id) and positive_id?(facts.actor_person_id) and
         nonempty?(facts.provider) and nonempty?(facts.channel_id) and
         optional_nonempty?(facts.thread_id) and valid_recipients? do
      :ok
    else
      {:error, :invalid_history_facts}
    end
  end

  defp validate_parent(%__MODULE__{parent: nil, thread_id: nil}, _strategy), do: :ok
  defp validate_parent(%__MODULE__{parent: nil, thread_id: _}, :replicated), do: :ok
  defp validate_parent(%__MODULE__{parent: nil}, _strategy), do: {:error, :missing_parent}
  defp validate_parent(%__MODULE__{thread_id: nil}, _strategy), do: {:error, :unexpected_parent}

  defp validate_parent(%__MODULE__{parent: %Transcript{} = parent} = facts, strategy) do
    matching_scope? =
      parent.parent_id == nil and parent.strategy == Atom.to_string(strategy) and
        parent.provider == facts.provider and
        parent.channel_config_id == facts.channel_config_id and
        parent.external_channel_id == facts.channel_id and
        match?({:ok, _}, Ecto.UUID.cast(parent.id))

    if matching_scope? and matching_resource?(parent, facts, strategy) do
      :ok
    else
      {:error, :parent_scope_mismatch}
    end
  end

  defp validate_parent(_facts, _strategy), do: {:error, :parent_scope_mismatch}

  defp matching_resource?(parent, facts, strategy) when strategy in [:direct, :shared] do
    parent.owner_person_id == nil and
      {parent.permission_resource_type, parent.permission_resource_id} ==
        ChannelHistoryResource.for(facts.provider, facts.channel_config_id, facts.channel_id)
  end

  defp matching_resource?(parent, _facts, :replicated),
    do:
      positive_id?(parent.owner_person_id) and parent.permission_resource_type == "person_history"

  defp positive_id?(id), do: is_integer(id) and id > 0

  defp nonempty?(value),
    do: is_binary(value) and String.trim(value) != "" and byte_size(value) <= 255

  defp optional_nonempty?(nil), do: true
  defp optional_nonempty?(value), do: nonempty?(value)
end
