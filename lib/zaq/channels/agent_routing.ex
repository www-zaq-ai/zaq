defmodule Zaq.Channels.AgentRouting do
  @moduledoc """
  Domain helpers for channel-to-agent routing choices.

  This module owns the persisted NONE sentinel and the runtime semantics for
  resolving ordered channel/provider/global agent candidates. UI modules may
  render these values, but labels and dropdown formatting live in BO helpers.
  """

  alias Zaq.Agent
  alias Zaq.Utils.ParseUtils

  @none_value "__none__"

  @doc "Returns the durable value used to disable agent routing."
  @spec none_value() :: String.t()
  def none_value, do: @none_value

  @doc "Returns a persisted select value for an agent id, NONE, or fallback."
  @spec select_value(term()) :: String.t()
  def select_value(value) when value in [nil, ""], do: ""
  def select_value(@none_value), do: @none_value
  def select_value("none"), do: @none_value
  def select_value(:none), do: @none_value
  def select_value(value), do: to_string(value)

  @doc "Parses a form/persisted agent choice into fallback, NONE, or a validated agent id."
  @spec validate_choice(term(), module()) :: {:ok, nil | :none | integer()} | {:error, term()}
  def validate_choice(raw_id, agent_module \\ Agent)

  def validate_choice(raw_id, _agent_module) when raw_id in [nil, ""], do: {:ok, nil}

  def validate_choice(raw_id, _agent_module) when raw_id in [@none_value, "none", :none],
    do: {:ok, :none}

  def validate_choice(raw_id, agent_module) when is_atom(agent_module) do
    case ParseUtils.parse_int_strict(raw_id) do
      {:ok, id} ->
        case agent_module.get_conversation_enabled_agent(id) do
          {:ok, _agent} -> {:ok, id}
          _ -> {:error, :invalid_agent}
        end

      :error ->
        {:error, :invalid_agent}
    end
  end

  @doc "Returns first effective agent selection from ordered candidates."
  @spec resolve_selection([{atom(), term()}], module()) :: {:ok, map() | :none | nil}
  def resolve_selection(candidates, agent_module \\ Agent)

  def resolve_selection(candidates, agent_module)
      when is_list(candidates) and is_atom(agent_module) do
    {:ok,
     Enum.find_value(candidates, fn {source, candidate_id} ->
       resolve_candidate(source, candidate_id, agent_module)
     end)}
  end

  @doc "Returns first conversation-eligible candidate, or nil for NONE/no match."
  @spec first_active_selection([{atom(), term()}], module()) :: map() | nil
  def first_active_selection(candidates, agent_module \\ Agent)

  def first_active_selection(candidates, agent_module)
      when is_list(candidates) and is_atom(agent_module) do
    {:ok, selection} = resolve_selection(candidates, agent_module)
    if selection == :none, do: nil, else: selection
  end

  defp resolve_candidate(_source, candidate_id, _agent_module)
       when candidate_id in [@none_value, "none", :none],
       do: :none

  defp resolve_candidate(source, candidate_id, agent_module) do
    with {:ok, id} <- ParseUtils.parse_int_strict(candidate_id),
         {:ok, _agent} <- agent_module.get_conversation_enabled_agent(id) do
      %{"agent_id" => id, "source" => Atom.to_string(source)}
    else
      _ -> nil
    end
  end
end
