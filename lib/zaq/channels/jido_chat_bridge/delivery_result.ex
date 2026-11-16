defmodule Zaq.Channels.JidoChatBridge.DeliveryResult do
  @moduledoc """
  Interprets adapter delivery observations and edit acknowledgments for Jido Chat.

  Telegram rejects an edit when the requested content and markup already match
  the target message. That specific response confirms the desired state; other
  errors retain their original failure semantics. Create responses never use
  this normalization, since a failed create cannot confirm an existing message.

  Mattermost HTTP status codes establish rejection only for attested response
  classes. Other HTTP results stay unconfirmed; their bodies are never evidence.
  """

  @unchanged_prefix "Bad Request: message is not modified:"

  @doc "Projects adapter-specific rejection evidence without retaining its response body."
  def delivery_observation(Jido.Chat.Mattermost.Adapter, {:error, {code, _body}})
      when code in 100..599 do
    if code in [400, 401, 403, 404, 405, 413, 415, 422, 429],
      do: %{outcome: :failed, reason: :rejected, provider_code: code},
      else: %{outcome: :unconfirmed, reason: :unknown, provider_code: code}
  end

  def delivery_observation(_adapter, _response), do: nil

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
