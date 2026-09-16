defmodule Zaq.Repo.Migrations.AddEditProfilePermission do
  use Ecto.Migration

  def up do
    replace_check(
      "'access_profile', 'edit_profile', 'access_message_history', 'share_conversations'"
    )
  end

  def down do
    # Never silently discard grants during a downgrade. Operators must revoke
    # edit_profile explicitly before reverting to the three-permission vocabulary.
    execute(fn ->
      if repo().query!(
           "SELECT 1 FROM people_permission_grants WHERE permission = 'edit_profile' LIMIT 1"
         ).num_rows > 0 do
        raise Ecto.MigrationError,
              "Revoke edit_profile grants before downgrading People permissions"
      end
    end)

    replace_check("'access_profile', 'access_message_history', 'share_conversations'")
  end

  defp replace_check(values) do
    drop constraint(:people_permission_grants, :people_permission_grants_permission_check)

    create constraint(:people_permission_grants, :people_permission_grants_permission_check,
             check: "permission IN (#{values})"
           )
  end
end
