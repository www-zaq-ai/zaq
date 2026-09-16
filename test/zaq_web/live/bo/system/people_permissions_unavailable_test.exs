defmodule ZaqWeb.Live.BO.System.PeoplePermissionsUnavailableTest do
  # This tests actual node availability by temporarily unregistering Engine.
  # Keep global process-name mutation out of the async People LiveView suite.
  use ZaqWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  alias Zaq.Accounts
  alias Zaq.Accounts.{PeoplePermissionGrant, PeoplePermissions}
  alias Zaq.Engine.Supervisor, as: EngineSupervisor
  alias Zaq.Repo

  test "a committed write followed by lost Engine requires reload without showing stale cells", %{
    conn: conn
  } do
    Repo.delete_all(PeoplePermissionGrant)
    user = admin_fixture()
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, view, _} = live(conn, ~p"/bo/people")
    render_click(view, "switch_tab", %{"tab" => "permissions"})
    engine = Process.whereis(EngineSupervisor)
    handler = "people-permission-engine-loss-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:zaq, :repo, :query],
      fn _, _, metadata, _ ->
        lose_engine_after_grant(metadata)
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      unless Process.whereis(EngineSupervisor), do: Process.register(engine, EngineSupervisor)
    end)

    assert view |> element("#permission-all_people-access_profile") |> render_click() =~
             "Permissions could not be loaded"

    refute has_element?(view, "#people-permissions-table")

    assert [%{scope_type: "all_people", permission: "access_profile"}] =
             PeoplePermissions.list_grants()

    :telemetry.detach(handler)
    Process.register(engine, EngineSupervisor)
    view |> element("#reload-people-permissions") |> render_click()
    assert has_element?(view, "#permission-all_people-access_profile[checked]")
  end

  test "failed write and reload remove stale controls; retry restores authoritative state", %{
    conn: conn
  } do
    Repo.delete_all(PeoplePermissionGrant)
    user = admin_fixture()
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    conn = init_test_session(conn, %{user_id: user.id})
    {:ok, view, _} = live(conn, ~p"/bo/people")
    render_click(view, "switch_tab", %{"tab" => "permissions"})
    assert has_element?(view, "#permission-all_people-access_profile")

    engine = Process.whereis(EngineSupervisor)
    Process.unregister(EngineSupervisor)

    on_exit(fn ->
      unless Process.whereis(EngineSupervisor), do: Process.register(engine, EngineSupervisor)
    end)

    assert view |> element("#permission-all_people-access_profile") |> render_click() =~
             "Permission change failed"

    refute has_element?(view, "#people-permissions-table")
    assert has_element?(view, "#reload-people-permissions")

    render_click(view, "set_permission", %{
      "scope" => "all_people",
      "permission" => "access_profile",
      "enabled" => true
    })

    assert PeoplePermissions.list_grants() == []

    assert view |> element("#reload-people-permissions") |> render_click() =~
             "Permissions could not be loaded"

    Process.register(engine, EngineSupervisor)
    view |> element("#reload-people-permissions") |> render_click()
    assert has_element?(view, "#permission-all_people-access_profile")
    refute has_element?(view, "#permission-all_people-access_profile[checked]")
  end

  defp lose_engine_after_grant(%{query: query}) do
    if String.starts_with?(query, "INSERT INTO \"people_permission_grants\"") do
      Process.unregister(EngineSupervisor)
    end
  end
end
