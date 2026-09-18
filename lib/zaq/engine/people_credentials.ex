defmodule Zaq.Engine.PeopleCredentials do
  @moduledoc """
  Authenticated People self-service credential operations at the Engine boundary.

  Bearer authentication and current permissions come from `PeopleAuth`. Credential
  ownership is always derived from that result; request attributes never select an
  owner. Reads require profile access (already enforced by authentication), while
  writes and OAuth authorization additionally require `manage_credentials`.
  """

  alias Zaq.Accounts.{PeopleAuth, PeoplePermissions}
  alias Zaq.Engine.Connect.{OAuthAttempts, PersonCredentials}
  alias Zaq.Repo

  @write_permissions [:access_profile, :manage_credentials]

  @spec dispatch(map(), keyword()) :: {:ok, term()} | {:error, term()}
  def dispatch(%{op: :list_self_credentials, token: token}, opts),
    do: authenticated(token, opts, :read, &PersonCredentials.list_available/1)

  def dispatch(%{op: :get_self_credential, token: token, credential_id: id}, opts),
    do: authenticated(token, opts, :read, &PersonCredentials.get_own_status(&1, id))

  def dispatch(
        %{op: :put_self_credential, token: token, credential_id: id, material: material},
        opts
      )
      when is_non_struct_map(material),
      do:
        authenticated(
          token,
          opts,
          :write,
          &PersonCredentials.put_own_authentication(&1, id, material, opts)
        )

  def dispatch(%{op: :revoke_self_credential, token: token, credential_id: id}, opts),
    do: authenticated(token, opts, :write, &PersonCredentials.revoke_own_grant(&1, id))

  def dispatch(%{op: :remove_self_credential, token: token, credential_id: id}, opts),
    do: authenticated(token, opts, :write, &PersonCredentials.remove_own_grant(&1, id))

  def dispatch(%{op: op, token: token, credential_id: id}, opts)
      when op in [:start_self_credential_oauth, :reconnect_self_credential_oauth] do
    with {:ok, prepared} <- prepare_oauth(token, id, opts) do
      OAuthAttempts.authorize_prepared(prepared, opts)
    end
  end

  def dispatch(_, _), do: {:error, :invalid_request}

  defp authenticated(token, opts, mode, operation) do
    Repo.transaction(fn ->
      with {:ok, auth} <- PeopleAuth.authenticate(token, opts),
           :ok <- authorize(auth, mode),
           {:ok, result} <- operation.(auth.person) do
        result
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp prepare_oauth(token, credential_id, opts) do
    Repo.transaction(fn ->
      with {:ok, auth} <- PeopleAuth.authenticate(token, opts),
           :ok <- authorize(auth, :write),
           {:ok, prepared} <-
             PersonCredentials.prepare_oauth(
               auth.person,
               auth.session.id,
               credential_id,
               opts
             ) do
        prepared
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp authorize(_auth, :read), do: :ok

  defp authorize(%{person: person}, :write) do
    if PeoplePermissions.allowed?(person, @write_permissions),
      do: :ok,
      else: {:error, :forbidden}
  end
end
