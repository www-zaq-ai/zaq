defmodule Zaq.Agent.ErrorMessage do
  @moduledoc """
  Canonical user-facing error message mapping for agent pipeline failures.

  Keeps error translation at the agent layer so all channels (BO, Mattermost,
  email, etc.) receive the same message payload.
  """

  @default_message "Something went wrong while answering your question. Please try again."
  @guard_message "I can’t help with that request, but I’m here to help with other questions you might have."

  @spec from_reason(term(), String.t() | nil) :: String.t()
  def from_reason(reason, fallback \\ nil)

  def from_reason(reason, _fallback) when reason in [:leaked, :guard_blocked],
    do: @guard_message

  def from_reason(:halted, _fallback),
    do: "Request was halted by a pipeline hook."

  def from_reason(:dispatch_error, _fallback),
    do: "Sorry, something went wrong. Please try again."

  def from_reason(_reason, fallback) when is_binary(fallback) and fallback != "",
    do: fallback

  def from_reason(_reason, _fallback),
    do: @default_message
end
