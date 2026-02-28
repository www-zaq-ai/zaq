defmodule Zaq.Accounts.SuperAdminSeeder do
  @moduledoc """
  This GenServer is responsible for seeding a super admin user on application startup.
  It checks for the existence of a super admin user and creates one if it doesn't exist,
  using the configuration provided in the application environment.
  """
  use GenServer
  require Logger

  alias Zaq.Accounts
  alias Zaq.Accounts.Role
  alias Zaq.Repo

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    unless Application.get_env(:zaq, :skip_super_admin_seed) do
      seed()
    end

    :ignore
  end

  defp seed do
    ensure_roles()
    ensure_super_admin()
  end

  defp ensure_roles do
    Enum.each(["super_admin", "admin", "staff"], fn name ->
      unless Repo.get_by(Role, name: name) do
        Accounts.create_role(%{name: name})
      end
    end)
  end

  defp ensure_super_admin do
    case Application.get_env(:zaq, :super_admin) do
      nil ->
        Logger.warning("No :super_admin config found. Skipping super admin creation.")

      config ->
        username = Keyword.get(config, :username)

        case Accounts.get_user_by_username(username) do
          nil ->
            role = Accounts.get_role_by_name("super_admin")

            {:ok, _user} =
              Accounts.create_user(%{
                username: username,
                role_id: role.id,
                must_change_password: true
              })

            Logger.info(
              "Super admin '#{username}' created. Password change required on first login."
            )

          _user ->
            Logger.debug("Super admin already exists. Skipping.")
        end
    end
  end
end
