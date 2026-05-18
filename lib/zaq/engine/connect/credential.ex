defmodule Zaq.Engine.Connect.Credential do
  @moduledoc "Provider-scoped reusable credential configuration."

  use Ecto.Schema

  import Ecto.Changeset

  @auth_kinds ~w(api_key oauth2)
  @request_formats ~w(bearer raw)

  schema "connect_credentials" do
    field :name, :string
    field :provider, :string
    field :auth_kind, :string
    field :user_level, :boolean, default: false
    field :request_format, :string, default: "bearer"
    field :metadata, :map, default: %{}

    field :client_id, :string
    field :client_secret, Zaq.Types.EncryptedString
    field :scopes, {:array, :string}, default: []

    field :api_key, Zaq.Types.EncryptedString
    field :expires_at, :utc_datetime

    has_many :grants, Zaq.Engine.Connect.Grant, foreign_key: :credential_id

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name provider auth_kind request_format user_level metadata)a
  @optional_fields ~w(client_id client_secret scopes api_key expires_at)a

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t() | nil,
          provider: String.t() | nil,
          auth_kind: String.t() | nil,
          user_level: boolean() | nil,
          request_format: String.t() | nil,
          metadata: map() | nil,
          client_id: String.t() | nil,
          client_secret: String.t() | nil,
          scopes: [String.t()] | nil,
          api_key: String.t() | nil,
          expires_at: DateTime.t() | nil,
          grants: [Zaq.Engine.Connect.Grant.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required([:name, :provider, :auth_kind, :request_format])
    |> validate_inclusion(:auth_kind, @auth_kinds)
    |> validate_inclusion(:request_format, @request_formats)
    |> validate_length(:name, min: 2, max: 255)
    |> validate_length(:provider, min: 2, max: 255)
    |> validate_auth_fields()
    |> unique_constraint(:name)
  end

  defp validate_auth_fields(changeset) do
    case get_field(changeset, :auth_kind) do
      "oauth2" ->
        changeset
        |> validate_required([:client_id])
        |> validate_length(:client_id, min: 2, max: 255)

      "api_key" ->
        changeset

      _ ->
        changeset
    end
  end
end
