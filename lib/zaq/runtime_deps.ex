defmodule Zaq.RuntimeDeps do
  @moduledoc false

  alias Zaq.Agent.{Answering, PromptGuard, Retrieval}
  alias Zaq.Channels.{ChannelConfig, Retrieval.MattermostAPI}
  alias Zaq.Ingestion.DocumentProcessor
  alias Zaq.NodeRouter

  @spec node_router() :: module()
  def node_router, do: get(:node_router, NodeRouter)

  @spec chat_live_node_router() :: module()
  def chat_live_node_router, do: get(:chat_live_node_router_module, NodeRouter)

  @spec channel_config() :: module()
  def channel_config, do: get(:channels_live_channel_config_module, ChannelConfig)

  @spec mattermost_api() :: module()
  def mattermost_api, do: get(:channels_live_mattermost_api_module, MattermostAPI)

  @spec http_client() :: module()
  def http_client, do: get(:channels_live_http_client, HTTPoison)

  @spec prompt_guard() :: module()
  def prompt_guard, do: get(:agent_prompt_guard_module, PromptGuard)

  @spec retrieval() :: module()
  def retrieval, do: get(:agent_retrieval_module, Retrieval)

  @spec document_processor() :: module()
  def document_processor, do: get(:agent_document_processor_module, DocumentProcessor)

  @spec answering() :: module()
  def answering, do: get(:agent_answering_module, Answering)

  @spec get(atom(), any()) :: any()
  def get(key, default), do: Application.get_env(:zaq, key, default)
end
