defmodule Zaq.Engine.Connect.Grant do
  @moduledoc "Context-bound grant derived from a reusable credential configuration."

  use Ecto.Schema

  import Ecto.Changeset

  @auth_kinds ~w(api_key oauth2 jwt_bearer)
  @request_formats ~w(bearer raw)
  @resource_types ~w(data_source mcp ai_provider_credential)
  @owner_types ~w(org user)
  @statuses ~w(active revoked expired)

  schema "connect_grants" do
    field :provider, :string
    field :auth_kind, :string

    field :resource_type, :string
    field :resource_id, :string

    field :owner_type, :string
    field :owner_id, :integer

    field :request_format, :string, default: "bearer"
    field :metadata, :map, default: %{}
    field :expires_at, :utc_datetime
    field :status, :string, default: "active"

    field :access_token, Zaq.Types.EncryptedString
    field :refresh_token, Zaq.Types.EncryptedString
    field :scopes, {:array, :string}, default: []
    field :api_key, Zaq.Types.EncryptedString
    field :issuer, :string
    field :private_key, Zaq.Types.EncryptedString
    field :key_id, :string
    field :subject, :string

    belongs_to :credential, Zaq.Engine.Connect.Credential

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(credential_id provider auth_kind resource_type resource_id owner_type request_format metadata status)a
  @optional_fields ~w(owner_id expires_at access_token refresh_token scopes api_key issuer private_key key_id subject)a

  @type t :: %__MODULE__{
          id: integer() | nil,
          credential_id: integer() | nil,
          credential: Zaq.Engine.Connect.Credential.t() | Ecto.Association.NotLoaded.t(),
          provider: String.t() | nil,
          auth_kind: String.t() | nil,
          resource_type: String.t() | nil,
          resource_id: String.t() | nil,
          owner_type: String.t() | nil,
          owner_id: integer() | nil,
          request_format: String.t() | nil,
          metadata: map() | nil,
          expires_at: DateTime.t() | nil,
          status: String.t() | nil,
          access_token: String.t() | nil,
          refresh_token: String.t() | nil,
          scopes: [String.t()] | nil,
          api_key: String.t() | nil,
          issuer: String.t() | nil,
          private_key: String.t() | nil,
          key_id: String.t() | nil,
          subject: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required([
      :credential_id,
      :provider,
      :auth_kind,
      :resource_type,
      :resource_id,
      :owner_type,
      :request_format,
      :status
    ])
    |> validate_inclusion(:auth_kind, @auth_kinds)
    |> validate_inclusion(:resource_type, @resource_types)
    |> validate_inclusion(:owner_type, @owner_types)
    |> validate_inclusion(:request_format, @request_formats)
    |> validate_inclusion(:status, @statuses)
    |> validate_auth_fields()
    |> foreign_key_constraint(:credential_id)
  end

  defp validate_auth_fields(changeset) do
    case get_field(changeset, :auth_kind) do
      "oauth2" ->
        changeset
        |> validate_required([:access_token])

      "api_key" ->
        changeset
        |> validate_required([:api_key])

      "jwt_bearer" ->
        changeset
        |> validate_required([:issuer, :private_key, :key_id])

      _ ->
        changeset
    end
  end
end
