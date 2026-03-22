defmodule ZaqWeb.Live.BO.Communication.NotificationLogsLiveTest do
  use ZaqWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  setup :verify_on_exit!

  alias Zaq.Engine.Notifications.NotificationLog
  alias Zaq.Repo

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp log_fixture(attrs \\ %{}) do
    defaults = %{
      sender: "system",
      payload: %{"subject" => "Hello", "body" => "World"}
    }

    {:ok, log} = NotificationLog.create_log(Map.merge(defaults, attrs))
    log
  end

  defp authed_conn(conn) do
    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :channels@localhost end)
    user = user_fixture()
    {:ok, user} = Zaq.Accounts.change_password(user, %{password: "StrongPass1!"})
    init_test_session(conn, %{user_id: user.id})
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "mount" do
    test "mounts at /bo/channels/notifications/logs with valid session", %{conn: conn} do
      conn = authed_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/bo/channels/notifications/logs")
      assert html =~ "Notification Logs"
    end

    test "redirects to login without session", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/bo/login"}}} =
               live(conn, ~p"/bo/channels/notifications/logs")
    end
  end

  describe "empty state" do
    test "shows empty state when no logs exist", %{conn: conn} do
      conn = authed_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/bo/channels/notifications/logs")
      assert html =~ "No notifications sent yet"
    end
  end

  describe "log table" do
    test "lists sender and recipient name", %{conn: conn} do
      log_fixture(%{sender: "knowledge_gap", recipient_name: "Alice"})
      conn = authed_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/bo/channels/notifications/logs")
      assert html =~ "knowledge_gap"
      assert html =~ "Alice"
    end

    test "shows status badge", %{conn: conn} do
      {:ok, log} =
        NotificationLog.create_log(%{
          sender: "system",
          payload: %{"subject" => "S", "body" => "B"}
        })

      NotificationLog.transition_status(log, "sent")

      conn = authed_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/bo/channels/notifications/logs")
      assert html =~ "sent"
    end

    test "shows ✓ badge for successful channel attempt", %{conn: conn} do
      {:ok, log} =
        NotificationLog.create_log(%{
          sender: "system",
          payload: %{"subject" => "S", "body" => "B"}
        })

      NotificationLog.append_attempt(log.id, "email", :ok)

      conn = authed_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/bo/channels/notifications/logs")
      assert html =~ "✓"
      assert html =~ "email"
    end

    test "shows ✗ badge for failed channel attempt", %{conn: conn} do
      {:ok, log} =
        NotificationLog.create_log(%{
          sender: "system",
          payload: %{"subject" => "S", "body" => "B"}
        })

      NotificationLog.append_attempt(log.id, "email", {:error, :smtp_down})

      conn = authed_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/bo/channels/notifications/logs")
      assert html =~ "✗"
    end
  end

  describe "view more modal" do
    test "clicking view more opens modal with subject and body", %{conn: conn} do
      {:ok, log} =
        NotificationLog.create_log(%{
          sender: "system",
          payload: %{"subject" => "My Subject", "body" => "My Body Text"}
        })

      conn = authed_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/bo/channels/notifications/logs")

      html =
        view
        |> element("button[phx-value-id='#{log.id}']")
        |> render_click()

      assert html =~ "My Subject"
      assert html =~ "My Body Text"
    end

    test "closing modal hides payload", %{conn: conn} do
      log_fixture()
      conn = authed_conn(conn)
      {:ok, view, _html} = live(conn, ~p"/bo/channels/notifications/logs")

      log = Repo.one!(NotificationLog)

      view
      |> element("button[phx-value-id='#{log.id}']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='close_modal']")
        |> render_click()

      refute html =~ "Notification Details"
    end
  end

  describe "pagination" do
    test "shows total count", %{conn: conn} do
      Enum.each(1..3, fn i ->
        log_fixture(%{sender: "sender_#{i}"})
      end)

      conn = authed_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/bo/channels/notifications/logs")
      assert html =~ "3 total"
    end

    test "next page navigates forward", %{conn: conn} do
      # Insert 21 logs to exceed the per_page of 20
      Enum.each(1..21, fn i ->
        log_fixture(%{sender: "sender_#{i}"})
      end)

      conn = authed_conn(conn)
      {:ok, view, html} = live(conn, ~p"/bo/channels/notifications/logs")
      assert html =~ "Page 1 of 2"

      html = view |> element("button", "Next →") |> render_click()
      assert html =~ "Page 2 of 2"
    end

    test "prev page is disabled on first page", %{conn: conn} do
      log_fixture()
      conn = authed_conn(conn)
      {:ok, _view, html} = live(conn, ~p"/bo/channels/notifications/logs")
      assert html =~ "← Prev"
    end
  end
end
