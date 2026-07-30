defmodule Zaq.Channels.ChannelConfig do
  @moduledoc """
  Schema for channel connector configurations stored in the database.
  Single-tenant: one config per provider (mattermost, slack, teams, etc.).

  ## Kinds
  - `:data_source` — document source adapters (Google Drive, SharePoint, ...)
  - `:retrieval` — messaging platform adapters (Mattermost, Slack, Email, ...)
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  require Logger

  alias Zaq.Channels.AgentRouting
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Types.EncryptedString
  alias Zaq.Utils.ParseUtils

  @smtp_provider "email:smtp"
  @imap_provider "email:imap"
  @valid_kinds ~w(data_source retrieval)
  @valid_providers ~w(mattermost slack teams google_drive sharepoint email:smtp email:imap telegram discord)

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
    |> maybe_validate_imap_settings()
    |> maybe_validate_imap_smtp_dependency_on_persist()
    |> unique_constraint(:provider)
    |> maybe_encrypt_token()
  end

  def to_runtime_config(nil), do: nil

  def to_runtime_config(%__MODULE__{} = config) do
    %{config | token: runtime_token(config.token)}
  end

  def to_runtime_config(config) when is_map(config) do
    config
    |> maybe_put_runtime_token(:token)
    |> maybe_put_runtime_token("token")
  end

  defp maybe_require_connection_fields(changeset) do
    kind = get_field(changeset, :kind)

    case {kind, get_field(changeset, :provider)} do
      {"data_source", _provider} ->
        changeset
        |> maybe_put_placeholder(:url)
        |> maybe_put_placeholder(:token)

      {_kind, @smtp_provider} ->
        validate_required(changeset, [:settings])

      {_kind, @imap_provider} ->
        validate_required(changeset, [:settings, :token])

      {_kind, _provider} ->
        validate_required(changeset, [:url, :token])
    end
  end

  defp maybe_put_placeholder(changeset, field) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, "")
      _ -> changeset
    end
  end

  defp maybe_validate_imap_settings(changeset) do
    case get_field(changeset, :provider) do
      @imap_provider ->
        case extract_imap_mailboxes(get_field(changeset, :settings)) do
          {:ok, mailboxes} -> validate_imap_mailboxes(changeset, mailboxes)
          :error -> add_error(changeset, :settings, "imap.selected_mailboxes is required")
        end

      _ ->
        changeset
    end
  end

  defp extract_imap_mailboxes(settings) when is_map(settings) do
    case Map.get(settings, "imap") do
      %{} = imap ->
        case Map.get(imap, "selected_mailboxes") do
          mailboxes when is_list(mailboxes) -> {:ok, mailboxes}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp extract_imap_mailboxes(_), do: :error

  defp validate_imap_mailboxes(changeset, mailboxes) do
    normalized =
      mailboxes
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if normalized == [] do
      add_error(changeset, :settings, "imap.selected_mailboxes must contain at least one mailbox")
    else
      changeset
    end
  end

  defp maybe_validate_imap_smtp_dependency_on_persist(changeset) do
    prepare_changes(changeset, fn persisted_changeset ->
      provider = get_field(persisted_changeset, :provider)
      enabled = get_field(persisted_changeset, :enabled)

      if provider == @imap_provider and enabled and not smtp_enabled?(persisted_changeset.repo) do
        add_error(
          persisted_changeset,
          :enabled,
          "email:imap requires an enabled email:smtp configuration"
        )
      else
        persisted_changeset
      end
    end)
  end

  defp smtp_enabled?(repo) do
    match?(%__MODULE__{}, repo.get_by(__MODULE__, provider: @smtp_provider, enabled: true))
  end

  defp maybe_encrypt_token(changeset) do
    changeset
    |> force_loaded_token_change()
    |> encrypt_token_change()
  end

  defp maybe_put_runtime_token(config, key) do
    case Map.fetch(config, key) do
      {:ok, token} -> Map.put(config, key, runtime_token(token))
      :error -> config
    end
  end

  defp runtime_token(token) when is_binary(token) do
    case EncryptedString.decrypt(token) do
      {:ok, decrypted} ->
        decrypted

      {:error, reason} ->
        if EncryptedString.encrypted?(token) do
          Logger.warning("Channel config token decryption failed: #{inspect(reason)}")
        end

        token
    end
  end

  defp runtime_token(token), do: token

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
  Returns enabled configs for a given kind (`:ingestion`, `:data_source`, or `:retrieval`),
  filtered to the given list of provider strings.
  """
  def list_enabled_by_kind(kind, providers) when kind in [:ingestion, :data_source, :retrieval] do
    kind_str = kind_to_config_kind(kind)
    providers = normalize_filter_providers(providers)

    __MODULE__
    |> where(
      [c],
      c.kind == ^kind_str and c.enabled == true and
        (c.provider in ^providers or fragment("split_part(?, ':', 1)", c.provider) in ^providers)
    )
    |> Zaq.Repo.all()
  end

  @doc "Returns enabled receiving channel configs that can route incoming messages for a person channel platform."
  def list_incoming_routing_configs_for_platform(platform) when is_binary(platform) do
    :retrieval
    |> list_enabled_by_kind([platform])
    |> Enum.filter(&incoming_routing_config_for_platform?(&1, platform))
  end

  def list_incoming_routing_configs_for_platform(_platform), do: []

  defp incoming_routing_config_for_platform?(%__MODULE__{provider: @imap_provider}, "email"),
    do: true

  defp incoming_routing_config_for_platform?(%__MODULE__{provider: @smtp_provider}, "email"),
    do: false

  defp incoming_routing_config_for_platform?(%__MODULE__{provider: provider}, platform),
    do: provider == platform

  defp normalize_filter_providers(providers) when is_list(providers) do
    providers
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_filter_providers(_providers), do: []

  defp kind_to_config_kind(:ingestion), do: "data_source"
  defp kind_to_config_kind(kind), do: Atom.to_string(kind)

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

  @doc "Returns jido_chat settings map for a channel config."
  def jido_chat_settings(%__MODULE__{settings: settings}) when is_map(settings) do
    settings
    |> Map.get("jido_chat", %{})
    |> case do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  def jido_chat_settings(%{settings: settings}) when is_map(settings) do
    settings
    |> Map.get("jido_chat", %{})
    |> case do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  def jido_chat_settings(_), do: %{}

  @doc "Returns a single jido_chat setting by key."
  def jido_chat_setting(config, key, default \\ nil) when is_binary(key) do
    Map.get(jido_chat_settings(config), key, default)
  end

  @doc "Returns bot name from jido_chat settings."
  def jido_chat_bot_name(config) do
    jido_chat_setting(config, "bot_name")
  end

  @doc "Returns bot user id from jido_chat settings."
  def jido_chat_bot_user_id(config) do
    jido_chat_setting(config, "bot_user_id")
  end

  @doc "Returns imap settings map for an email:imap config."
  def imap_settings(%__MODULE__{settings: settings}) when is_map(settings) do
    settings
    |> Map.get("imap", %{})
    |> case do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  def imap_settings(%{settings: settings}) when is_map(settings) do
    settings
    |> Map.get("imap", %{})
    |> case do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  def imap_settings(_), do: %{}

  @doc "Returns selected mailboxes for email:imap config."
  def imap_selected_mailboxes(config) do
    config
    |> imap_settings()
    |> Map.get("selected_mailboxes", [])
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc "Returns provider-level default configured agent id from the routing-rule table."
  def get_provider_default_agent_id(config) do
    config
    |> get_provider_agent_choice()
    |> agent_choice_id()
  end

  defp agent_choice_id(nil), do: nil
  defp agent_choice_id(choice) when is_integer(choice), do: choice

  defp agent_choice_id(choice) do
    if choice == AgentRouting.none_value(), do: nil, else: choice
  end

  @doc "Returns provider-level agent routing choice, including NONE when configured."
  def get_provider_agent_choice(%__MODULE__{id: id}) when is_integer(id) do
    case IncomingMessageRouting.get_rule(%{channel_config_id: id}) do
      %{routing_mode: :none} -> AgentRouting.none_value()
      %{routing_mode: :agent, configured_agent_id: configured_agent_id} -> configured_agent_id
      _ -> nil
    end
  end

  def get_provider_agent_choice(_config), do: nil

  @doc "Sets or clears provider-level default configured agent id in settings."
  def set_provider_default_agent_id(%__MODULE__{} = config, agent_id) do
    rule =
      cond do
        agent_id in [AgentRouting.none_value(), "none", :none] ->
          %{channel_config_id: config.id, routing_mode: :none}

        is_nil(ParseUtils.parse_optional_int(agent_id)) ->
          %{channel_config_id: config.id, routing_mode: :clear}

        true ->
          %{
            channel_config_id: config.id,
            routing_mode: :agent,
            configured_agent_id: ParseUtils.parse_optional_int(agent_id)
          }
      end

    case dispatch_incoming_routing_rules([rule]) do
      {:ok, _result} -> {:ok, config}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_incoming_routing_rules(rules) do
    %{rules: rules, raw_errors: true}
    |> Event.new(:engine, opts: [action: :upsert_incoming_message_routing_rules])
    |> NodeRouter.dispatch()
    |> Map.get(:response)
  end
end
