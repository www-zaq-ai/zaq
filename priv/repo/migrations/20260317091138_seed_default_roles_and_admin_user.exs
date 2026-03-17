defmodule Zaq.Repo.Migrations.SeedDefaultRolesAndAdminUser do
  use Ecto.Migration

  @default_roles ["super_admin", "admin", "staff", "public"]

  def up do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    role_rows =
      Enum.map(@default_roles, fn name ->
        %{name: name, meta: %{}, inserted_at: now, updated_at: now}
      end)

    repo().insert_all("roles", role_rows,
      on_conflict: :nothing,
      conflict_target: [:name]
    )

    super_admin_role_id = fetch_role_id!("super_admin")

    repo().insert_all(
      "users",
      [
        %{
          username: "admin",
          password_hash: Bcrypt.hash_pwd_salt("admin"),
          role_id: super_admin_role_id,
          must_change_password: true,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:username]
    )
  end

  def down do
    :ok
  end

  defp fetch_role_id!(role_name) do
    case repo().query!("SELECT id FROM roles WHERE name = $1 LIMIT 1", [role_name]).rows do
      [[role_id]] -> role_id
      _ -> raise "role '#{role_name}' not found while seeding admin user"
    end
  end
end
