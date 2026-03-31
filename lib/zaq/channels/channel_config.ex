defmodule Zaq.Channels.ChannelConfig do
  @moduledoc """
  Schema for channel connector configurations stored in the database.
  Single-tenant: one config per provider (mattermost, slack, teams, etc.).

  ## Kinds
  - `:ingestion` — document source adapters (Google Drive, SharePoint, ...)
  - `:retrieval` — messaging platform adapters (Mattermost, Slack, Email, ...)
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Zaq.Types.EncryptedString

  @smtp_provider "email:smtp"
  @valid_kinds ~w(ingestion retrieval)
  @valid_providers ~w(mattermost slack teams google_drive sharepoint email:smtp)

  @test_message "✅ **Zaq Connection Test**\nThis is an automated test message. If you see this, the channel is configured correctly."

  schema "channel_configs" do
    field :name, :string
    field :provider, :string
    field :kind, :string
    field :url, :string
    field :token, Zaq.Types.EncryptedString
    field :enabled, :boolean, default: true
    field :settings, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:name, :provider, :kind, :url, :token, :enabled, :settings])
    |> validate_required([:name, :provider, :kind])
    |> validate_inclusion(:provider, @valid_providers)
    |> validate_inclusion(:kind, @valid_kinds)
    |> maybe_require_connection_fields()
    |> unique_constraint(:provider)
    |> maybe_encrypt_token()
  end

  defp maybe_require_connection_fields(changeset) do
    case get_field(changeset, :provider) do
      @smtp_provider -> validate_required(changeset, [:settings])
      _provider -> validate_required(changeset, [:url, :token])
    end
  end

  defp maybe_encrypt_token(changeset) do
    changeset
    |> force_loaded_token_change()
    |> encrypt_token_change()
  end

  defp force_loaded_token_change(changeset) do
    if changeset.data.__meta__.state == :loaded do
      case get_field(changeset, :token) do
        nil -> changeset
        token -> force_change(changeset, :token, token)
      end
    else
      changeset
    end
  end

  defp encrypt_token_change(changeset) do
    case get_change(changeset, :token) do
      token when token in [nil, ""] -> changeset
      token when is_binary(token) -> encrypt_token_value(changeset, token)
      _other -> changeset
    end
  end

  defp encrypt_token_value(changeset, token) do
    if EncryptedString.encrypted?(token) do
      changeset
    else
      case EncryptedString.encrypt(token) do
        {:ok, encrypted} -> put_change(changeset, :token, encrypted)
        {:error, reason} -> token_encryption_error(changeset, reason)
      end
    end
  end

  defp token_encryption_error(changeset, :missing_encryption_key) do
    add_error(changeset, :token, "could not be encrypted: missing SYSTEM_CONFIG_ENCRYPTION_KEY")
  end

  defp token_encryption_error(changeset, :invalid_encryption_key) do
    add_error(changeset, :token, "could not be encrypted: invalid SYSTEM_CONFIG_ENCRYPTION_KEY")
  end

  defp token_encryption_error(changeset, _reason) do
    add_error(changeset, :token, "could not be encrypted")
  end

  @doc """
  Returns all enabled configs for a given kind (`:ingestion` or `:retrieval`).
  """
  def list_enabled_by_kind(kind) when kind in [:ingestion, :retrieval] do
    kind_str = Atom.to_string(kind)

    __MODULE__
    |> where([c], c.kind == ^kind_str and c.enabled == true)
    |> Zaq.Repo.all()
  end

  def get_by_provider(provider) do
    Zaq.Repo.get_by(__MODULE__, provider: provider, enabled: true)
  end

  @doc "Returns a config for `provider`, including disabled entries."
  def get_any_by_provider(provider) do
    Zaq.Repo.get_by(__MODULE__, provider: provider)
  end

  @doc """
  Upserts a provider config.

  `attrs` can include any ChannelConfig fields; provider is always forced to the
  function argument.
  """
  def upsert_by_provider(provider, attrs) when is_binary(provider) and is_map(attrs) do
    attrs = Map.put(attrs, :provider, provider)

    case get_any_by_provider(provider) do
      nil ->
        %__MODULE__{}
        |> changeset(attrs)
        |> Zaq.Repo.insert()

      %__MODULE__{} = config ->
        config
        |> changeset(attrs)
        |> Zaq.Repo.update()
    end
  end

  @doc """
  Returns the enabled ChannelConfig for a given provider and platform-specific
  channel ID, by joining through retrieval_channels. Returns nil if not found.

  Both `provider` and `channel_id` are required to avoid collisions: two
  different providers may share the same channel ID string.
  """
  def get_by_channel_id(provider, channel_id) do
    Zaq.Channels.RetrievalChannel
    |> join(:inner, [r], c in __MODULE__, on: r.channel_config_id == c.id)
    |> where(
      [r, c],
      r.channel_id == ^channel_id and c.provider == ^provider and c.enabled == true
    )
    |> select([_r, c], c)
    |> Zaq.Repo.one()
  end

  def test_connection(%__MODULE__{provider: "mattermost"} = config, channel_id) do
    Jido.Chat.Mattermost.Adapter.send_message(
      channel_id,
      @test_message,
      url: config.url,
      token: config.token
    )
  end

  def test_connection(%__MODULE__{} = config, _channel_id) do
    {:error, "Testing not supported for #{config.provider}"}
  end
end
