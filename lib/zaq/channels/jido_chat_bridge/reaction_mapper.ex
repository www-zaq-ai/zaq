defmodule Zaq.Channels.JidoChatBridge.ReactionMapper do
  @moduledoc """
  Maps provider-specific reaction representations to feedback ratings.

  This module normalizes reactions from supported chat providers into
  provider-agnostic numeric ratings before they are dispatched to the engine.
  """

  @doc """
  Returns `{:ok, rating}` for a recognised emoji, or `:ignored` for
  unmapped reactions.
  """

  @spec to_rating(String.t(), atom()) :: {:ok, pos_integer()} | :ignored
  def to_rating(emoji, provider) when is_binary(emoji) and is_atom(provider) do
    case emoji_to_rating(emoji, provider) do
      {:ok, _rating} = result -> result
      _ -> :ignored
    end
  end

  # Unicode forms (Telegram sends these)
  defp emoji_to_rating("\u{1F44D}", _provider), do: {:ok, 5}
  defp emoji_to_rating("\u{1F525}", _provider), do: {:ok, 5}

  # Mattermost / Slack short names
  defp emoji_to_rating("thumbsup", :mattermost), do: {:ok, 5}
  defp emoji_to_rating("thumbs_up", :mattermost), do: {:ok, 5}
  defp emoji_to_rating("+1", :mattermost), do: {:ok, 5}
  defp emoji_to_rating("thumbsup", :slack), do: {:ok, 5}
  defp emoji_to_rating("thumbs_up", :slack), do: {:ok, 5}
  defp emoji_to_rating("+1", :slack), do: {:ok, 5}

  # Discord also uses short names in some contexts
  defp emoji_to_rating("thumbsup", :discord), do: {:ok, 5}
  defp emoji_to_rating("+1", :discord), do: {:ok, 5}

  # Negative
  defp emoji_to_rating("\u{1F44E}", _provider), do: {:ok, 1}

  defp emoji_to_rating("thumbsdown", :mattermost), do: {:ok, 1}
  defp emoji_to_rating("thumbs_down", :mattermost), do: {:ok, 1}
  defp emoji_to_rating("-1", :mattermost), do: {:ok, 1}
  defp emoji_to_rating("thumbsdown", :slack), do: {:ok, 1}
  defp emoji_to_rating("thumbs_down", :slack), do: {:ok, 1}
  defp emoji_to_rating("-1", :slack), do: {:ok, 1}

  defp emoji_to_rating("thumbsdown", :discord), do: {:ok, 1}
  defp emoji_to_rating("-1", :discord), do: {:ok, 1}

  # Fallback
  defp emoji_to_rating(_emoji, _provider), do: nil
end
