defmodule Zaq.Engine.Connect.OAuthAttempt do
  @moduledoc """
  Short-lived server-bound OAuth authorization, shared by Person connection and trusted
  admin global setup. The random ID is the only browser-state payload. PKCE and the
  optional admin candidate are strictly encrypted before insert and erased on claim.
  `claimed_at` is irreversible; it is not a retry lease. No authorization code is stored.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{}

  schema "connect_oauth_attempts" do
    field :credential_id, :integer
    field :owner_type, :string
    field :owner_id, :integer
    belongs_to :session, Zaq.Accounts.PersonSession, type: :binary_id
    field :provider, :string
    field :config_fingerprint, :binary, redact: true
    field :redirect_uri, :string
    field :pkce_verifier, Zaq.Types.EncryptedString, redact: true
    field :candidate_config, Zaq.Types.EncryptedString, redact: true
    field :expires_at, :utc_datetime_usec
    field :claimed_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(attempt, trusted_attrs) do
    attempt
    |> change(trusted_attrs)
    |> validate_required([
      :id,
      :owner_type,
      :provider,
      :config_fingerprint,
      :redirect_uri,
      :expires_at
    ])
    |> foreign_key_constraint(:credential_id)
    |> foreign_key_constraint(:session_id)
    |> check_constraint(:owner_type, name: :connect_oauth_attempt_owner_check)
  end
end
