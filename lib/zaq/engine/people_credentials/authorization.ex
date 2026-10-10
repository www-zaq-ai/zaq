defmodule Zaq.Engine.PeopleCredentials.Authorization do
  @moduledoc """
  Shared authorization boundary for People credential management and deferred OAuth
  completion. Accounts owns identity/session validation and permission evaluation;
  this module owns the credential-management permission requirement. Session-bound
  revalidation requires an outer transaction to retain Accounts locks until completion.
  No caller-supplied Person/owner attributes or credential schemas are interpreted here.
  """
  alias Zaq.Accounts.{PeopleAuth, PeoplePermissions}
  alias Zaq.Repo

  @write_permissions [:access_profile, :manage_credentials]

  @doc "Authenticates a bearer and applies this boundary's read/write policy."
  def authenticate(token, mode, opts) when mode in [:read, :write] do
    with {:ok, auth} <- PeopleAuth.authenticate(token, opts),
         :ok <- authorize(auth, mode) do
      {:ok, auth}
    end
  end

  @doc "Revalidates the initiating session and write permission while retaining identity locks."
  def revalidate_session(person_id, session_id, opts) do
    if Repo.in_transaction?() do
      with {:ok, auth} <- PeopleAuth.revalidate_session(person_id, session_id, opts),
           :ok <- authorize(auth, :write) do
        {:ok, auth}
      end
    else
      {:error, :transaction_required}
    end
  end

  defp authorize(_auth, :read), do: :ok

  defp authorize(%{person: person}, :write) do
    if PeoplePermissions.allowed?(person, @write_permissions), do: :ok, else: {:error, :forbidden}
  end
end
