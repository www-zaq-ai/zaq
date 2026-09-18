defmodule Zaq.System.AIProviderCredential do
  @moduledoc """
  AI-specific provider and endpoint configuration.

  Authentication is owned by the associated Connect credential. The legacy `api_key`
  remains only for migration/rollback compatibility and is not a runtime authority.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "ai_provider_credentials" do
    field :name, :string
    field :provider, :string
    field :endpoint, :string
    field :api_key, Zaq.Types.EncryptedString
    field :metadata, :map, default: %{}
    field :sovereign, :boolean, default: false
    field :description, :string

    belongs_to :connect_credential, Zaq.Engine.Connect.Credential

    timestamps(type: :utc_datetime)
  end

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [
      :name,
      :provider,
      :endpoint,
      :api_key,
      :metadata,
      :sovereign,
      :description,
      :connect_credential_id
    ])
    |> validate_required([:name, :provider, :endpoint, :connect_credential_id])
    |> validate_length(:name, max: 255)
    |> validate_length(:provider, max: 255)
    |> validate_length(:endpoint, max: 2048)
    |> unique_constraint(:name)
    |> unique_constraint(:connect_credential_id,
      name: :ai_provider_credentials_connect_credential_index
    )
    |> foreign_key_constraint(:connect_credential_id)
  end
end
