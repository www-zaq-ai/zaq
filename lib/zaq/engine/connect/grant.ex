defmodule Zaq.Engine.Connect.Grant do
  @moduledoc """
  Resource- or credential-bound grant derived from reusable configuration.

  Legacy `changeset/2` retains resource-bound org/user grants. Credential-bound
  grants use `credential_changeset/3`, derive authentication fields from configuration,
  and own their secrets. Canonical resources use `connect_credential` and the
  credential ID string. Person ownership uses `owner_id`; org ownership has no ID.
  Each credential/owner has one slot
  across all statuses. Reconnection updates that row; revocation retains it.
  Internal refresh claims use a UUID and bounded expiration, set only by the shared
  refresh boundary rather than accepted through either material changeset.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @auth_kinds ~w(api_key oauth2 jwt_bearer)
  @request_formats ~w(bearer raw)
  @resource_types ~w(data_source mcp ai_provider_credential)
  @owner_types ~w(org user)
  @statuses ~w(active revoked expired)
  @configuration_fields ~w(provider auth_kind request_format scopes issuer key_id)a

  schema "connect_grants" do
    field :provider, :string
    field :auth_kind, :string

    field :resource_type, :string
    field :resource_id, :string

    field :owner_type, :string
    field :owner_id, :integer

    field :request_format, :string, default: "bearer"
    field :metadata, :map, default: %{}, redact: true
    field :expires_at, :utc_datetime
    field :status, :string, default: "active"
    field :refresh_claim, Ecto.UUID, redact: true
    field :refresh_claim_until, :utc_datetime

    field :access_token, Zaq.Types.EncryptedString, redact: true
    field :refresh_token, Zaq.Types.EncryptedString, redact: true
    field :scopes, {:array, :string}, default: []
    field :api_key, Zaq.Types.EncryptedString, redact: true
    field :issuer, :string
    field :private_key, Zaq.Types.EncryptedString, redact: true
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
          refresh_claim: Ecto.UUID.t() | nil,
          refresh_claim_until: DateTime.t() | nil,
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

  @doc false
  @spec compatible_configuration?(t(), Zaq.Engine.Connect.Credential.t()) :: boolean()
  def compatible_configuration?(grant, credential) do
    Map.take(grant, @configuration_fields) == Map.take(credential, @configuration_fields) and
      grant.subject == Zaq.Utils.Map.metadata_subject(credential.metadata)
  end

  @doc "Builds a canonical storage changeset from trusted configuration, without copying secrets."
  @spec credential_changeset(t(), Zaq.Engine.Connect.Credential.t(), map()) :: Ecto.Changeset.t()
  def credential_changeset(grant, credential, attrs) do
    derived_fields = [
      :credential_id,
      :resource_type,
      :resource_id,
      :provider,
      :auth_kind,
      :request_format,
      :scopes,
      :issuer,
      :key_id,
      :subject
    ]

    grant
    |> cast(attrs, (@required_fields ++ @optional_fields) -- derived_fields)
    |> put_change(:credential_id, credential.id)
    |> put_change(:resource_type, "connect_credential")
    |> put_change(:resource_id, to_string(credential.id))
    |> put_change(:provider, credential.provider)
    |> put_change(:auth_kind, credential.auth_kind)
    |> put_change(:request_format, credential.request_format)
    |> put_change(:scopes, credential.scopes)
    |> put_change(:issuer, credential.issuer)
    |> put_change(:key_id, credential.key_id)
    |> put_change(
      :subject,
      Zaq.Utils.Map.read_any(credential.metadata || %{}, ["subject", :subject])
    )
    |> validate_required([
      :credential_id,
      :provider,
      :auth_kind,
      :request_format,
      :owner_type,
      :status
    ])
    |> validate_inclusion(:auth_kind, @auth_kinds)
    |> validate_inclusion(:request_format, @request_formats)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:owner_type, ["org", "person"])
    |> validate_credential_owner()
    |> validate_auth_fields()
    |> foreign_key_constraint(:credential_id)
    |> check_constraint(:resource_id, name: :connect_grants_resource_check)
    |> check_constraint(:owner_id, name: :connect_grants_owner_check)
    |> unique_constraint(:credential_id, name: :connect_grants_credential_person_index)
    |> unique_constraint(:credential_id, name: :connect_grants_credential_org_index)
  end

  @doc "Protected lifecycle owner-only transfer; never validates or rewrites retained secret material."
  @spec transfer_owner_changeset(t(), pos_integer()) :: Ecto.Changeset.t()
  def transfer_owner_changeset(
        %__MODULE__{owner_type: "person", resource_type: "connect_credential"} = grant,
        person_id
      ) do
    grant
    |> change(owner_id: person_id)
    |> validate_required([:owner_id])
    |> validate_number(:owner_id, greater_than: 0)
    |> check_constraint(:owner_id, name: :connect_grants_owner_check)
    |> unique_constraint(:credential_id, name: :connect_grants_credential_person_index)
  end

  defp validate_credential_owner(changeset) do
    if get_field(changeset, :owner_type) == "person" do
      validate_required(changeset, [:owner_id])
    else
      validate_absent(changeset, [:owner_id])
    end
  end

  defp validate_absent(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      if is_nil(get_field(acc, field)),
        do: acc,
        else: add_error(acc, field, "must be absent for this binding")
    end)
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

  @doc "Checks decrypted JWT material locally; shared by canonical mutation and runtime usability."
  @spec private_key?(term()) :: boolean()
  def private_key?(value) when is_binary(value) do
    with [entry] <- :public_key.pem_decode(value),
         key when is_tuple(key) <- :public_key.pem_entry_decode(entry) do
      elem(key, 0) in [:RSAPrivateKey, :ECPrivateKey]
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def private_key?(_), do: false
end
