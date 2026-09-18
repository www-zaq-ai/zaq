defmodule Zaq.Engine.Connect.Credential do
  @moduledoc """
  Provider-scoped reusable credential configuration.

  Personal policy defaults to disabled and is independent of legacy `user_level`.
  `secret_binding: :configuration` preserves legacy JWT private-key validation;
  explicit `:grant` mode allows that key to be supplied on credential-bound grants.
  JWT issuer, key ID and authentication profile remain configuration requirements.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Zaq.Utils.Map, as: MapUtils

  @auth_kinds ~w(api_key oauth2 jwt_bearer)
  @request_formats ~w(bearer raw)

  schema "connect_credentials" do
    field :name, :string
    field :provider, :string
    field :auth_kind, :string
    field :user_level, :boolean, default: false

    field :personal_credential_policy, Ecto.Enum,
      values: [:disabled, :optional, :required],
      default: :disabled

    field :secret_binding, Ecto.Enum, values: [:configuration, :grant], default: :configuration
    field :request_format, :string, default: "bearer"
    field :metadata, :map, default: %{}, redact: true

    field :client_id, :string
    field :client_secret, Zaq.Types.EncryptedString, redact: true
    field :scopes, {:array, :string}, default: []
    field :issuer, :string
    field :private_key, Zaq.Types.EncryptedString, redact: true
    field :key_id, :string

    field :api_key, Zaq.Types.EncryptedString, redact: true
    field :expires_at, :utc_datetime

    has_many :grants, Zaq.Engine.Connect.Grant, foreign_key: :credential_id

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name provider auth_kind request_format user_level metadata)a
  @optional_fields ~w(client_id client_secret scopes api_key expires_at issuer private_key key_id personal_credential_policy secret_binding)a

  @type t :: %__MODULE__{
          id: integer() | nil,
          name: String.t() | nil,
          provider: String.t() | nil,
          auth_kind: String.t() | nil,
          user_level: boolean() | nil,
          personal_credential_policy: :disabled | :optional | :required,
          secret_binding: :configuration | :grant,
          request_format: String.t() | nil,
          metadata: map() | nil,
          client_id: String.t() | nil,
          client_secret: String.t() | nil,
          scopes: [String.t()] | nil,
          issuer: String.t() | nil,
          private_key: String.t() | nil,
          key_id: String.t() | nil,
          api_key: String.t() | nil,
          expires_at: DateTime.t() | nil,
          grants: [Zaq.Engine.Connect.Grant.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required([
      :name,
      :provider,
      :auth_kind,
      :request_format,
      :personal_credential_policy,
      :secret_binding
    ])
    |> validate_inclusion(:auth_kind, @auth_kinds)
    |> validate_inclusion(:request_format, @request_formats)
    |> validate_length(:name, min: 2, max: 255)
    |> validate_length(:provider, min: 2, max: 255)
    |> validate_auth_fields()
    |> unique_constraint(:name)
    |> check_constraint(:personal_credential_policy,
      name: :connect_credentials_personal_policy_check
    )
    |> check_constraint(:secret_binding, name: :connect_credentials_secret_binding_check)
  end

  defp validate_auth_fields(changeset) do
    case get_field(changeset, :auth_kind) do
      "oauth2" ->
        changeset
        |> validate_required([:client_id])
        |> validate_length(:client_id, min: 2, max: 255)

      "api_key" ->
        changeset

      "jwt_bearer" ->
        changeset
        |> validate_required([:issuer, :key_id])
        |> validate_configuration_private_key()
        |> validate_length(:issuer, min: 2, max: 255)
        |> validate_length(:key_id, min: 2, max: 255)
        |> validate_metadata_auth_profile()

      _ ->
        changeset
    end
  end

  defp validate_configuration_private_key(changeset) do
    if get_field(changeset, :secret_binding) == :grant,
      do: changeset,
      else: validate_required(changeset, [:private_key])
  end

  defp validate_metadata_auth_profile(changeset) do
    metadata = get_field(changeset, :metadata) || %{}
    profile = MapUtils.read_any(metadata, ["auth_profile_id", :auth_profile_id])
    subject = MapUtils.read_any(metadata, ["subject", :subject])

    if profile in ["service_account", "domain_delegated_service_account"] do
      validate_delegation_subject(changeset, profile, subject)
    else
      add_error(
        changeset,
        :metadata,
        "auth_profile_id must be service_account or domain_delegated_service_account"
      )
    end
  end

  defp validate_delegation_subject(changeset, "domain_delegated_service_account", subject) do
    if is_binary(subject) and String.trim(subject) != "" do
      changeset
    else
      add_error(changeset, :metadata, "subject is required for domain_delegated_service_account")
    end
  end

  defp validate_delegation_subject(changeset, _profile, _subject), do: changeset
end
