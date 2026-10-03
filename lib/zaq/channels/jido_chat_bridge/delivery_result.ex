defmodule Zaq.Channels.JidoChatBridge.DeliveryResult do
  @moduledoc """
  Normalizes adapter edit acknowledgments at the Channels boundary.

  Telegram rejects an edit when the requested content and markup already match
  the target message. That specific response confirms the desired state; other
  errors retain their original failure semantics. Create responses never use
  this normalization, since a failed create cannot confirm an existing message.
  """

  @unchanged_prefix "Bad Request: message is not modified:"

  @doc "Normalizes an edit result without exposing provider error interpretation to consumers."
  def normalize_edit(adapter, result)

  def normalize_edit(
        Jido.Chat.Telegram.Adapter,
        {:error, %ExGram.Error{code: :response_status_not_match, message: body}} = error
      )
      when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"ok" => false, "error_code" => 400, "description" => description}}
      when is_binary(description) ->
        if String.starts_with?(description, @unchanged_prefix), do: :ok, else: error

      _ ->
        error
    end
  end

  def normalize_edit(_adapter, :ok), do: :ok
  def normalize_edit(_adapter, {:ok, _}), do: :ok
  def normalize_edit(_adapter, {:error, _} = error), do: error
  def normalize_edit(_adapter, other), do: {:error, {:unexpected_response, other}}
end
