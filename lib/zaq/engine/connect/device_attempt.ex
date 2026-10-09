defmodule Zaq.Engine.Connect.DeviceAttempt do
  @moduledoc """
  Short-lived device sign-in binding. Transient protocol and admin candidate material
  are strictly encrypted before insert, redacted, and erased at terminal transitions.
  The persisted worker PID identifies one node/process incarnation, never a restart lease.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{}
  schema "connect_device_attempts" do
    field :credential_id, :integer
    field :owner_type, :string
    field :owner_id, :integer
    belongs_to :session, Zaq.Accounts.PersonSession, type: :binary_id
    field :provider, :string
    field :config_fingerprint, :binary, redact: true
    field :candidate_config, Zaq.Types.EncryptedString, redact: true
    field :device_material, Zaq.Types.EncryptedString, redact: true
    field :worker_pid, :binary
    field :verification_uri, :string
    field :user_code, Zaq.Types.EncryptedString, redact: true
    field :interval, :integer
    field :expires_at, :utc_datetime_usec
    field :status, :string, default: "pending"
    field :result_credential_id, :integer
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(attempt, trusted_attrs) do
    attempt
    |> change(trusted_attrs)
    |> validate_required([:id, :owner_type, :provider, :config_fingerprint, :expires_at, :status])
    |> foreign_key_constraint(:credential_id)
    |> foreign_key_constraint(:session_id)
    |> check_constraint(:owner_type, name: :connect_device_attempt_owner_check)
    |> check_constraint(:status, name: :connect_device_attempt_status_check)
  end
end
