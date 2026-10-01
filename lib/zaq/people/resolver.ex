defmodule Zaq.People.Resolver do
  @moduledoc """
  Normalizes raw channel adapter payloads into canonical person attrs maps.

  Each platform normalizer maps the platform-specific field names to the
  shared keys expected by `Zaq.Accounts.People`: `channel_id`, `username`,
  `display_name`, `email`, `phone`, and `dm_channel_id`.

  Resolution (match/create logic) is handled by `Zaq.People.IdentityPlug`,
  which calls `normalize/2` and then delegates to `Zaq.Accounts.People`.
  """

  # ---------------------------------------------------------------------------
  # Platform normalizers
  # ---------------------------------------------------------------------------

  def normalize("mattermost", attrs), do: normalize_slack_style(attrs)
  def normalize("slack", attrs), do: normalize_slack_style(attrs)

  def normalize("microsoft_teams", attrs) do
    %{
      "channel_id" => get(attrs, :azure_ad_id) || get(attrs, :channel_id),
      "username" => get(attrs, :email) || get(attrs, :username),
      "display_name" => get(attrs, :full_name) || get(attrs, :display_name),
      "email" => get(attrs, :email)
    }
  end

  def normalize("whatsapp", attrs) do
    phone = get(attrs, :phone) || get(attrs, :channel_id)

    %{
      "channel_id" => phone,
      "phone" => phone
    }
  end

  def normalize("telegram", attrs) do
    first = get(attrs, :first_name) || ""
    last = get(attrs, :last_name) || ""
    display = String.trim("#{first} #{last}")

    %{
      "channel_id" => get(attrs, :chat_id) || get(attrs, :channel_id),
      "username" => get(attrs, :handle) || get(attrs, :username),
      "display_name" => if(display != "", do: display, else: get(attrs, :display_name))
    }
  end

  def normalize("discord", attrs) do
    name = get(attrs, :name)
    discriminator = get(attrs, :discriminator)

    username =
      if is_binary(name) and is_binary(discriminator),
        do: "#{name}##{discriminator}",
        else: name || get(attrs, :username)

    %{
      "channel_id" => get(attrs, :snowflake) || get(attrs, :channel_id),
      "username" => username,
      "display_name" => get(attrs, :nickname) || get(attrs, :display_name)
    }
  end

  def normalize("email", attrs) do
    email = get(attrs, :email) || get(attrs, :channel_id)

    %{
      "channel_id" => email,
      "email" => email,
      "display_name" => get(attrs, :display_name)
    }
  end

  # The chat channel (`ZaqWeb.ChatCompletionsController`) has no profile API to
  # enrich from — see `Zaq.People.IdentityResolver.maybe_enrich/4` — so the
  # calling backend is the only source of the user's identity, carried on
  # `author_name` by `Zaq.Channels.ChatBridge`.
  #
  # `author_name` reaches here as `:username`, but it is mapped to
  # `display_name`: the platform has no handle, and `display_name` is what seeds
  # the Person's `full_name` — without it every chat Person lands in the People
  # directory named after the opaque caller user id.
  #
  # No `"email"` key, deliberately. `Zaq.Accounts.People.match_person/1` matches
  # on email FIRST and platform-agnostically, so emitting one here would let any
  # holder of the shared `ZAQ_CHAT_TOKEN` select an arbitrary existing Person by
  # guessing its address — inheriting that Person's `team_ids` (widening
  # retrieval past public documents) and overwriting its `full_name`. The chat
  # channel authenticates the calling *service*, never the end user, so its
  # identity claims may only ever key a chat-owned Person.
  def normalize("chat", attrs) do
    %{
      "channel_id" => get(attrs, :channel_id),
      "display_name" => get(attrs, :display_name) || get(attrs, :username)
    }
  end

  def normalize("email:imap", attrs), do: normalize("email", attrs)

  def normalize(_platform, attrs) do
    %{
      "channel_id" => get(attrs, :channel_id),
      "username" => get(attrs, :username),
      "display_name" => get(attrs, :display_name),
      "email" => get(attrs, :email),
      "phone" => get(attrs, :phone)
    }
  end

  defp normalize_slack_style(attrs) do
    %{
      "channel_id" => get(attrs, :user_id) || get(attrs, :channel_id),
      "username" => get(attrs, :handle) || get(attrs, :username),
      "display_name" => get(attrs, :full_name) || get(attrs, :display_name),
      "email" => get(attrs, :email),
      "dm_channel_id" => get(attrs, :dm_channel_id)
    }
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp get(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end
end
