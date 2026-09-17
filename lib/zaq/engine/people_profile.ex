defmodule Zaq.Engine.PeopleProfile do
  @moduledoc """
  Authenticated People self-profile operations at the Engine boundary.

  The bearer is the sole profile owner coordinate. An outer transaction retains
  authentication's Person/session locks through edits, and every edit rechecks the
  current profile and edit grants. Responses expose only self-service fields and
  digest-free profile data.
  """

  alias Zaq.Accounts.{People, PeopleAuth, PeoplePermissions}
  alias Zaq.Repo

  @enforce_keys [:person, :teams, :channels, :permissions]
  defstruct [:person, :teams, :channels, :permissions]

  @type t :: %__MODULE__{
          person: map(),
          teams: [map()],
          channels: [map()],
          permissions: MapSet.t(Zaq.Accounts.PeoplePermissionGrant.permission())
        }

  @doc "Executes an authenticated self-profile operation from the fixed Engine gateway."
  @spec dispatch(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def dispatch(%{op: :profile, token: token}, opts) do
    profile_operation(token, opts, &{:ok, &1.person})
  end

  def dispatch(%{op: :update_self_profile, token: token, attrs: attrs}, opts)
      when is_non_struct_map(attrs) do
    edit_profile(token, opts, &People.update_self_profile(&1, attrs))
  end

  def dispatch(
        %{op: :update_self_channel_weight, token: token, channel_id: id, attrs: attrs},
        opts
      )
      when is_non_struct_map(attrs) do
    edit_profile(token, opts, &update_channel_weight(&1, id, attrs))
  end

  def dispatch(
        %{op: :update_self_channel_order, token: token, ids: ids, expected: expected},
        opts
      ) do
    edit_profile(token, opts, &update_channel_order(&1, ids, expected))
  end

  def dispatch(_, _), do: {:error, :invalid_request}

  defp edit_profile(token, opts, update) do
    profile_operation(token, opts, fn %{person: person} ->
      if PeoplePermissions.allowed?(person, [:access_profile, :edit_profile]),
        do: update.(person),
        else: {:error, :forbidden}
    end)
  end

  defp update_channel_weight(person, id, attrs) do
    with {:ok, _} <- People.update_self_channel_weight(person, id, attrs), do: {:ok, person}
  end

  defp update_channel_order(person, ids, expected) do
    with {:ok, _} <- People.update_self_channel_order(person, ids, expected), do: {:ok, person}
  end

  defp profile_operation(token, opts, operation) do
    Repo.transaction(fn ->
      with {:ok, auth} <- PeopleAuth.authenticate(token, opts),
           {:ok, person} <- operation.(auth) do
        profile_data(person, auth.permissions)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp profile_data(person, permissions) do
    %__MODULE__{
      person: Map.take(person, [:full_name, :email, :phone, :role, :status]),
      teams:
        People.list_teams()
        |> Enum.filter(&(&1.id in person.team_ids))
        |> Enum.map(&Map.take(&1, [:id, :name])),
      channels:
        person.id
        |> People.list_person_channels()
        |> Enum.map(&Map.take(&1, [:id, :platform, :channel_identifier, :weight])),
      permissions: permissions
    }
  end
end
