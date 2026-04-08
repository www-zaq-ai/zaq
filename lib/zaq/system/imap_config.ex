defmodule Zaq.System.ImapConfig do
  @moduledoc """
  Embedded schema for validating and working with the email (IMAP) configuration form.
  """

  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :enabled, :boolean, default: false
    field :url, :string
    field :port, :integer, default: 993
    field :ssl, :boolean, default: true
    field :ssl_depth, :integer, default: 3
    field :username, :string
    field :password, :string
    field :selected_mailboxes, {:array, :string}, default: ["INBOX"]
    field :mark_as_read, :boolean, default: true
    field :load_initial_unread, :boolean, default: false
    field :poll_interval, :integer, default: 30_000
    field :idle_timeout, :integer, default: 1_500_000
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :enabled,
      :url,
      :port,
      :ssl,
      :ssl_depth,
      :username,
      :password,
      :selected_mailboxes,
      :mark_as_read,
      :load_initial_unread,
      :poll_interval,
      :idle_timeout
    ])
    |> maybe_require_fields()
    |> validate_format(:url, ~r/^(?:imaps?:\/\/)?[^\s\/]+(?::\d+)?$/,
      message: "must be a valid IMAP host or URL"
    )
    |> validate_number(:port, greater_than: 0, less_than_or_equal_to: 65_535)
    |> validate_number(:ssl_depth, greater_than_or_equal_to: 0)
    |> validate_number(:poll_interval, greater_than: 0)
    |> validate_number(:idle_timeout, greater_than: 0)
    |> validate_selected_mailboxes()
  end

  defp maybe_require_fields(changeset) do
    if get_field(changeset, :enabled) do
      validate_required(changeset, [:url, :username, :password, :selected_mailboxes],
        message: "is required when IMAP is enabled"
      )
    else
      changeset
    end
  end

  defp validate_selected_mailboxes(changeset) do
    value = get_field(changeset, :selected_mailboxes, [])

    if normalize_mailboxes(value) == [] do
      add_error(changeset, :selected_mailboxes, "must contain at least one mailbox")
    else
      changeset
    end
  end

  def normalize_mailboxes(value) when is_binary(value) do
    value
    |> String.split([",", "\n", ";"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def normalize_mailboxes(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def normalize_mailboxes(_), do: []
end
