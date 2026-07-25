defmodule Zaq.Channels.JidoChatBridge.ReactionMapper do
  @moduledoc """
  Maps provider-specific reaction representations to feedback ratings.

  This module normalizes reactions from supported chat providers into
  provider-agnostic numeric ratings before they are dispatched to the engine.
  """

  @doc """
  Returns `{:ok, rating}` for a recognised emoji, or `:ignored` for
  unmapped reactions.

  Total by design: callers run inside the bridge state process and pass
  provider-supplied values, so a missing or malformed emoji must be ignored
  rather than raise.
  """
  @spec to_rating(term(), term()) :: {:ok, pos_integer()} | :ignored
  def to_rating(provider, emoji) when is_binary(emoji) and is_atom(provider) do
    case emoji_to_rating(provider, emoji) do
      {:ok, _rating} = result -> result
      _ -> :ignored
    end
  end

  def to_rating(_provider, _emoji), do: :ignored

  # Unicode forms (Telegram sends these)
  defp emoji_to_rating(_provider, "\u{1F44D}"), do: {:ok, 5}
  defp emoji_to_rating(_provider, "\u{1F525}"), do: {:ok, 5}

  # Mattermost / Slack short names
  defp emoji_to_rating(:mattermost, "thumbsup"), do: {:ok, 5}
  defp emoji_to_rating(:mattermost, "thumbs_up"), do: {:ok, 5}
  defp emoji_to_rating(:mattermost, "+1"), do: {:ok, 5}
  defp emoji_to_rating(:slack, "thumbsup"), do: {:ok, 5}
  defp emoji_to_rating(:slack, "thumbs_up"), do: {:ok, 5}
  defp emoji_to_rating(:slack, "+1"), do: {:ok, 5}

  # Discord also uses short names in some contexts
  defp emoji_to_rating(:discord, "thumbsup"), do: {:ok, 5}
  defp emoji_to_rating(:discord, "+1"), do: {:ok, 5}

  # Negative
  defp emoji_to_rating(_provider, "\u{1F44E}"), do: {:ok, 1}

  defp emoji_to_rating(:mattermost, "thumbsdown"), do: {:ok, 1}
  defp emoji_to_rating(:mattermost, "thumbs_down"), do: {:ok, 1}
  defp emoji_to_rating(:mattermost, "-1"), do: {:ok, 1}
  defp emoji_to_rating(:slack, "thumbsdown"), do: {:ok, 1}
  defp emoji_to_rating(:slack, "thumbs_down"), do: {:ok, 1}
  defp emoji_to_rating(:slack, "-1"), do: {:ok, 1}

  defp emoji_to_rating(:discord, "thumbsdown"), do: {:ok, 1}
  defp emoji_to_rating(:discord, "-1"), do: {:ok, 1}

  # Fallback
  defp emoji_to_rating(_provider, _emoji), do: nil
end
