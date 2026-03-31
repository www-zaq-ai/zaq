defmodule Zaq.Channels.ChatBridge do
  @moduledoc """
  Wires Jido.Chat event handlers to the ZAQ pipeline.

  Maps `Jido.Chat.Incoming` to the internal `Zaq.Engine.Messages.Incoming` contract,
  runs `Pipeline.run/2`, posts the reply via `Chat.Thread.post/2`, and persists
  the conversation via `Conversations.persist_from_incoming/2`.

  All external module calls (Pipeline, Conversations, Accounts, Permissions) are
  configurable via Application env for testability.
  """

  alias Jido.Chat
  alias Zaq.Engine.Messages.Incoming

  @doc "Builds a Jido.Chat struct wired with ZAQ's mention and message handlers."
  def build(adapters) do
    Chat.new(user_name: "zaq", adapters: adapters)
    |> Chat.on_new_mention(&handle_incoming/2)
    |> Chat.on_new_message(~r/.+/, &handle_incoming/2)
  end

  @doc false
  def handle_incoming(thread, %Chat.Incoming{} = incoming) do
    msg = to_internal(incoming)

    with {:ok, role_ids} <- resolve_roles(msg),
         {:ok, result} <- pipeline_mod().run(msg.content, role_ids: role_ids),
         {:ok, _} <- Chat.Thread.post(thread, result.answer),
         :ok <- conversations_mod().persist_from_incoming(msg, result) do
      :ok
    end
  end

  @doc false
  def to_internal(%Chat.Incoming{} = incoming) do
    %Incoming{
      content: incoming.text,
      channel_id: incoming.external_room_id,
      thread_id: incoming.external_thread_id,
      message_id: incoming.external_message_id,
      author_id: incoming.author && incoming.author.user_id,
      author_name: incoming.author && incoming.author.user_name,
      provider: :mattermost,
      metadata: incoming.metadata
    }
  end

  @doc false
  def resolve_roles(%{author_name: nil}), do: {:ok, nil}

  def resolve_roles(%{author_name: author_name}) do
    role_ids =
      case accounts_mod().get_user_by_username(author_name) do
        nil -> nil
        user -> permissions_mod().list_accessible_role_ids(user)
      end

    {:ok, role_ids}
  end

  defp pipeline_mod,
    do: Application.get_env(:zaq, :chat_bridge_pipeline_module, Zaq.Agent.Pipeline)

  defp conversations_mod,
    do:
      Application.get_env(
        :zaq,
        :chat_bridge_conversations_module,
        Zaq.Engine.Conversations
      )

  defp accounts_mod,
    do: Application.get_env(:zaq, :chat_bridge_accounts_module, Zaq.Accounts)

  defp permissions_mod,
    do:
      Application.get_env(
        :zaq,
        :chat_bridge_permissions_module,
        Zaq.Accounts.Permissions
      )
end
