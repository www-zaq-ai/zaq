defmodule Zaq.Engine.Conversations.ConversationShare do
  @moduledoc "Ecto schema for a conversation share link or per-user share."

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Conversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversation_shares" do
    field :share_token, :string
    field :permission, :string, default: "read"
    field :expires_at, :utc_datetime

    belongs_to :conversation, Conversation

    belongs_to :shared_with_user, Zaq.Accounts.User,
      type: :integer,
      foreign_key: :shared_with_user_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @valid_permissions ~w[read]

  @doc "Changeset for creating a conversation share."
  def changeset(share, attrs) do
    share
    |> cast(attrs, [:conversation_id, :shared_with_user_id, :permission, :expires_at])
    |> validate_required([:conversation_id, :permission])
    |> validate_inclusion(:permission, @valid_permissions)
    |> put_share_token()
    |> unique_constraint(:share_token)
    |> unique_constraint([:conversation_id, :shared_with_user_id])
  end

  defp put_share_token(%{data: %{share_token: nil}} = changeset) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    put_change(changeset, :share_token, token)
  end

  defp put_share_token(%{data: %{share_token: existing}} = changeset)
       when is_binary(existing),
       do: changeset

  defp put_share_token(changeset) do
    if get_field(changeset, :share_token) do
      changeset
    else
      token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      put_change(changeset, :share_token, token)
    end
  end
end
