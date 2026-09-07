defmodule Zaq.Channels.JidoChatBridge.ReactionMapper do
  @moduledoc """
  Maps provider-specific reaction representations to feedback ratings.

  This module normalizes reactions from supported chat providers into
  provider-agnostic numeric ratings before they are dispatched to the engine.

  Mattermost thumb shortcodes accept optional paired colons and one standard
  skin-tone suffix. Only the existing thumb aliases are normalized; custom
  names, malformed shortcodes and other providers' representations are unchanged.
  """

  @mattermost_shortcode ~r/\A(:?)(\+1|-1|thumbsup|thumbs_up|thumbsdown|thumbs_down)(?:_(?:light|medium_light|medium|medium_dark|dark)_skin_tone)?\1\z/

  @doc """
  Returns `{:ok, rating}` for a recognised emoji, or `:ignored` for
  unmapped reactions.

  Mattermost accepts `+1`, `thumbsup`, `thumbs_up` (5) and `-1`, `thumbsdown`,
  `thumbs_down` (1), bare or colon-wrapped, optionally suffixed with
  `_light_skin_tone`, `_medium_light_skin_tone`, `_medium_skin_tone`,
  `_medium_dark_skin_tone` or `_dark_skin_tone`.

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

  defp emoji_to_rating(:mattermost, emoji) do
    case Regex.run(@mattermost_shortcode, emoji, capture: [2]) do
      [base] -> emoji_to_rating(:mattermost, base)
      nil -> nil
    end
  end

  # Fallback
  defp emoji_to_rating(_provider, _emoji), do: nil
end
