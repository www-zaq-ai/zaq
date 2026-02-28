alias Zaq.Repo
alias Zaq.Accounts.Role

roles = ["super_admin", "admin", "staff"]

Enum.each(roles, fn name ->
  unless Repo.get_by(Role, name: name) do
    Repo.insert!(%Role{name: name, meta: %{}})
  end
end)
