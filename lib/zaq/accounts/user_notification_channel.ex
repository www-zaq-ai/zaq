defmodule Zaq.Accounts.UserNotificationChannel do
  @moduledoc """
  Ecto schema for a BO user's notification channel preferences.

  Each user may have at most one entry per platform (enforced by unique index).
  The `is_preferred` flag marks the user's default channel for notifications.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "user_notification_channels" do
    belongs_to :user, Zaq.Accounts.User
    field :platform, :string
    field :identifier, :string
    field :is_preferred, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:platform, :identifier, :is_preferred])
    |> validate_required([:platform, :identifier])
    |> unique_constraint([:user_id, :platform],
      name: :user_notification_channels_user_id_platform_index
    )
  end
end
