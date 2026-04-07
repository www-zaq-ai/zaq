defmodule Zaq.People.Resolver do
  @moduledoc """
  Resolves a channel sender's identity to a Person record.

  Called at the bridge level for every incoming message. Platform-specific
  normalizers map raw adapter payloads to a canonical attrs map before
  the shared match/create logic runs.
  """

  alias Zaq.Accounts.People

  @spec resolve(atom() | String.t(), map()) :: {:ok, People.Person.t()} | {:error, term()}
  def resolve(platform, attrs) do
    platform_str = to_string(platform)
    canonical = normalize(platform_str, attrs)

    with {:ok, person} <- People.find_or_create_from_channel(platform_str, canonical) do
      channel = find_channel(person, platform_str, canonical["channel_id"])

      if channel do
        People.record_interaction(channel)
      end

      {:ok, person}
    end
  end

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

  defp find_channel(person, platform, channel_id) when is_binary(channel_id) do
    Enum.find(
      Map.get(person, :channels, []),
      &(&1.platform == platform and &1.channel_identifier == channel_id)
    )
  end

  defp find_channel(_person, _platform, _channel_id), do: nil
end
