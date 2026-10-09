defmodule Zaq.Accounts.PersonIdentities do
  @moduledoc """
  Resolves and claims canonical native identity ownership for People operations.
  Callers use the People mutation transaction. Channels supplies authority rules;
  connector links retain their own routing and preferences.
  """
  alias Zaq.Accounts.{Person, PersonChannel, PersonIdentity}
  alias Zaq.Channels.IdentityScope
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Repo
  import Ecto.Query

  @doc "Checks the stored authority before using a connector link after configuration edits."
  @spec current_scope?(PersonChannel.t()) :: boolean()
  def current_scope?(%PersonChannel{person_identity_id: nil}), do: true

  def current_scope?(%PersonChannel{} = channel) do
    expected =
      key(channel.platform, %{
        "channel_config_id" => channel.channel_config_id,
        "channel_id" => channel.channel_identifier
      })

    case Repo.get(PersonIdentity, channel.person_identity_id) do
      %PersonIdentity{} = identity ->
        Map.take(identity, [:platform, :authority, :identifier]) == expected

      _ ->
        false
    end
  end

  @doc "Transfers native identity ownership in the existing explicit Person merge transaction."
  @spec transfer(pos_integer(), [pos_integer()]) :: {non_neg_integer(), nil | [term()]}
  def transfer(survivor_id, loser_ids) do
    Repo.update_all(from(i in PersonIdentity, where: i.person_id in ^loser_ids),
      set: [person_id: survivor_id]
    )
  end

  defp key(platform, attrs) do
    config =
      if attrs["channel_config_id"], do: Repo.get(ChannelConfig, attrs["channel_config_id"])

    %{
      platform: platform,
      authority: IdentityScope.authority(platform, config),
      identifier: PersonChannel.normalize_identifier(platform, attrs["channel_id"])
    }
  end

  @spec lookup(String.t(), map()) :: {:ok, Person.t()} | {:error, :not_found}
  def lookup(platform, attrs) do
    key = key(platform, attrs)

    case key.identifier && Repo.get_by(PersonIdentity, key) do
      %PersonIdentity{person_id: id} -> {:ok, Repo.get!(Person, id)}
      _ -> {:error, :not_found}
    end
  end

  @spec claim(pos_integer(), String.t(), map()) ::
          {:ok, PersonIdentity.t()} | {:error, Ecto.Changeset.t()}
  def claim(person_id, platform, attrs) do
    key = key(platform, attrs)

    case key.identifier && Repo.get_by(PersonIdentity, key) do
      %PersonIdentity{person_id: ^person_id} = identity ->
        {:ok, identity}

      %PersonIdentity{} ->
        {:error,
         Ecto.Changeset.add_error(
           Ecto.Changeset.change(%PersonChannel{}),
           :channel_identifier,
           "This channel identifier is already assigned.",
           constraint: :unique,
           constraint_name: "person_identities_platform_authority_identifier_index"
         )}

      _ ->
        %PersonIdentity{}
        |> PersonIdentity.changeset(Map.put(key, :person_id, person_id))
        |> Repo.insert()
    end
  end

  @doc "Releases an identity only after its last explicit connector link was removed."
  @spec release_unlinked(pos_integer() | nil) :: :ok
  def release_unlinked(nil), do: :ok

  def release_unlinked(id) do
    if not Repo.exists?(from(c in PersonChannel, where: c.person_identity_id == ^id)),
      do: Repo.delete_all(from(i in PersonIdentity, where: i.id == ^id))

    :ok
  end
end
