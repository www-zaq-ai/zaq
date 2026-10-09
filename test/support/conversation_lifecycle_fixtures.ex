defmodule Zaq.ConversationLifecycleFixtures do
  @moduledoc "Fixtures using the same admission and finalization operations as live requests."

  alias Zaq.Engine.Conversations

  def complete_exchange(incoming, result, opts \\ []) do
    with {:ok, binding} <- Conversations.admit_incoming(incoming) do
      Conversations.finalize_incoming(
        binding.user_message_id,
        binding.finalization_token,
        result,
        opts
      )
    end
  end
end
