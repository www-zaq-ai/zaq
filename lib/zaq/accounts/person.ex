defmodule Zaq.Accounts.Person do
  @moduledoc """
  Stored person identity and profile. Optional email addresses are trimmed and
  Unicode-lowercased at the changeset boundary; blank email is stored as nil.
  Ordinary changesets exclude identity history. The protected merge-result
  changeset validates the complete result supplied by identity consolidation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w(active inactive)

  @type t :: %__MODULE__{}

  schema "people" do
    field :full_name, :string
    field :email, :string
    field :phone, :string
    field :role, :string
    field :status, :string, default: "active"
    field :incomplete, :boolean, default: true
    field :metadata, :map, default: %{}
    field :team_ids, {:array, :integer}, default: []
    # Internal identity state: persisted only through People's merge-result operation.
    field :merged_person_ids, {:array, :integer}, default: []
    field :merge_history, Zaq.Types.JsonArray, default: []

    has_many :channels, Zaq.Accounts.PersonChannel

    timestamps(type: :utc_datetime)
  end

  def changeset(person, attrs) do
    person
    |> cast(attrs, [:full_name, :email, :phone, :role, :status, :metadata, :team_ids])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:full_name])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:email)
    |> put_incomplete_flag()
  end

  def update_changeset(person, attrs) do
    person
    |> cast(attrs, [:full_name, :email, :phone, :role, :status, :metadata, :team_ids])
    |> update_change(:email, &normalize_email/1)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:email)
    |> put_incomplete_flag()
  end

  @doc "Protected identity consolidation changeset; never use for ordinary request attributes."
  @spec merge_result_changeset(t(), map()) :: Ecto.Changeset.t()
  def merge_result_changeset(person, attrs) do
    person
    |> update_changeset(attrs)
    |> cast(attrs, [:merged_person_ids, :merge_history])
  end

  @doc "Canonical email identity shared by storage and matching; does not validate email syntax."
  @spec normalize_email(String.t() | nil) :: String.t() | nil
  def normalize_email(nil), do: nil

  def normalize_email(email) when is_binary(email) do
    case email |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  # Sets incomplete: false only when full_name, email, and phone are all present.
  defp put_incomplete_flag(changeset) do
    full_name = get_field(changeset, :full_name)
    email = get_field(changeset, :email)
    phone = get_field(changeset, :phone)

    complete? =
      is_binary(full_name) and full_name != "" and
        is_binary(email) and email != "" and
        is_binary(phone) and phone != ""

    put_change(changeset, :incomplete, not complete?)
  end
end
