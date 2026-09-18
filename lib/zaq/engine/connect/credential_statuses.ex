defmodule Zaq.Engine.Connect.CredentialStatuses do
  @moduledoc """
  Secret-free lifecycle projections for canonical credential owner slots.

  This is a trusted Connect read boundary, not caller authentication. Explicit owners
  select one canonical slot; callers must authorize any administrative transport before
  invoking it. Person self-service continues to derive ownership through PeopleAuth.
  """

  import Ecto.Query

  alias Zaq.Engine.Connect.{Credential, Grant, Mutations}
  alias Zaq.Repo
  alias Zaq.Utils.DateUtils

  @type lifecycle_status :: String.t()
  @type summary :: %{
          credential_id: pos_integer(),
          name: String.t(),
          provider: String.t(),
          auth_kind: String.t(),
          personal_credential_policy: :disabled | :optional | :required,
          status: lifecycle_status(),
          expires_at: DateTime.t() | nil
        }
  @type result :: {:ok, summary()} | {:error, :invalid_owner | :not_found}

  @doc "Returns one safe status for a trusted explicit canonical owner."
  @spec get(Mutations.credential_ref(), Mutations.owner(), keyword()) :: result()
  def get(reference, owner, opts \\ []) do
    with {:ok, id} <- credential_id(reference),
         {:ok, owner_type, owner_id} <- owner(owner),
         %{} = row <- Repo.one(status_query(owner_type, owner_id) |> where([c], c.id == ^id)) do
      {:ok, project(row, DateUtils.now(opts))}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc "Lists safe statuses for eligible personal configurations and one trusted Person ID."
  @spec list_person(pos_integer(), keyword()) :: [summary()]
  def list_person(person_id, opts \\ []) do
    now = DateUtils.now(opts)

    rows =
      "person"
      |> status_query(person_id)
      |> where(
        [c],
        c.secret_binding == :grant and c.personal_credential_policy in [:optional, :required]
      )
      |> order_by([c], asc: c.name, asc: c.id)
      |> Repo.all()

    Enum.map(rows, &project(&1, now))
  end

  @doc "Returns an eligible or retained personal slot status for one trusted Person ID."
  @spec get_person(pos_integer(), Mutations.credential_ref(), keyword()) :: result()
  def get_person(person_id, reference, opts \\ []) do
    with {:ok, id} <- credential_id(reference),
         %{} = row <-
           Repo.one(
             "person"
             |> status_query(person_id)
             |> where([c], c.id == ^id)
             |> where(
               [c, g],
               (c.secret_binding == :grant and
                  c.personal_credential_policy in [:optional, :required]) or not is_nil(g.id)
             )
           ) do
      {:ok, project(row, DateUtils.now(opts))}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp status_query("org", nil) do
    from c in Credential,
      left_join: g in Grant,
      on:
        g.credential_id == c.id and g.resource_type == "connect_credential" and
          g.owner_type == "org" and is_nil(g.owner_id),
      select: %{
        credential_id: c.id,
        name: c.name,
        provider: c.provider,
        auth_kind: c.auth_kind,
        personal_credential_policy: c.personal_credential_policy,
        status: g.status,
        expires_at: g.expires_at
      }
  end

  defp status_query("person", owner_id) do
    from c in Credential,
      left_join: g in Grant,
      on:
        g.credential_id == c.id and g.resource_type == "connect_credential" and
          g.owner_type == "person" and g.owner_id == ^owner_id,
      select: %{
        credential_id: c.id,
        name: c.name,
        provider: c.provider,
        auth_kind: c.auth_kind,
        personal_credential_policy: c.personal_credential_policy,
        status: g.status,
        expires_at: g.expires_at
      }
  end

  defp project(%{status: nil} = row, _now), do: %{row | status: "absent"}

  defp project(%{status: "active", expires_at: %DateTime{} = expiry} = row, now) do
    if DateTime.compare(expiry, now) == :gt, do: row, else: %{row | status: "expired"}
  end

  defp project(row, _now), do: row

  defp credential_id(%Credential{id: id}), do: credential_id(id)

  defp credential_id(id) when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807,
    do: {:ok, id}

  defp credential_id(_), do: {:error, :not_found}

  defp owner(:org), do: {:ok, "org", nil}

  defp owner({:person, id})
       when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807,
       do: {:ok, "person", id}

  defp owner(_), do: {:error, :invalid_owner}
end
