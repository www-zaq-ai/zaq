defmodule Zaq.System.AIProviderCredential do
  @moduledoc """
  Schema for reusable AI provider credentials.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "ai_provider_credentials" do
    field :name, :string
    field :provider, :string
    field :endpoint, :string
    field :api_key, Zaq.Types.EncryptedString
    field :sovereign, :boolean, default: false
    field :description, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:name, :provider, :endpoint, :api_key, :sovereign, :description])
    |> validate_required([:name, :provider, :endpoint])
    |> validate_length(:name, max: 255)
    |> validate_length(:provider, max: 255)
    |> validate_length(:endpoint, max: 2048)
    |> unique_constraint(:name)
  end
end
