defmodule ZaqWeb.Live.BO.Communication.PlaygroundLiveTest do
  use ZaqWeb.ConnCase

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = user_fixture(%{username: "testadmin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: user.id})

    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :services@localhost end)

    %{conn: conn, user: user}
  end

  test "renders shell and uses a suggestion", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/playground")

    assert has_element?(view, "#chat-form")
    assert render(view) =~ "Welcome to ZAQ Playground!"

    view |> element("#suggestion-0") |> render_click()

    assert render(view) =~ "What is ZAQ and what does it do?"
  end

  test "handles deterministic status and pipeline messages", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/playground")

    send(view.pid, {:status_update, nil, :retrieving, "Searching..."})
    assert render(view) =~ "Searching..."

    send(
      view.pid,
      {:pipeline_result, nil, %{answer: "All good [source: guide.md]", confidence: 0.92}, "Q"}
    )

    html = render(view)
    assert html =~ "All good"
    assert html =~ "guide.md"
    refute html =~ "[source:"
  end

  test "opens and submits feedback modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/playground")

    view
    |> element(~s(button[phx-click="feedback"][phx-value-type="negative"]))
    |> render_click()

    assert has_element?(view, "#feedback-modal")

    view
    |> element(~s(button[phx-click="toggle_feedback_reason"][phx-value-reason="Too slow"]))
    |> render_click()

    view |> element("#submit-feedback-button") |> render_click()

    refute has_element?(view, "#feedback-modal")
  end

  test "ignores stale async messages in handle_info", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/playground")

    send(view.pid, {:status_update, "stale-req", :retrieving, "Should be ignored"})
    refute render(view) =~ "Should be ignored"

    send(
      view.pid,
      {:pipeline_result, "stale-req", %{answer: "Stale answer", confidence: 0.8}, "Q"}
    )

    refute render(view) =~ "Stale answer"
  end

  test "handles error pipeline result branch deterministically", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/playground")

    send(
      view.pid,
      {:pipeline_result, nil, %{answer: "Fallback error", confidence: 0, error: true}, "Q"}
    )

    html = render(view)
    assert html =~ "Fallback error"
    assert html =~ "text-red-600"
  end

  test "supports feedback modal open-close and reason toggle combinations", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/playground")

    view
    |> element(~s(button[phx-click="feedback"][phx-value-type="negative"]))
    |> render_click()

    assert has_element?(view, "#feedback-modal")

    view
    |> element(~s(button[phx-click="toggle_feedback_reason"][phx-value-reason="Too slow"]))
    |> render_click()

    assert render(view) =~ "background:#03b6d4; color:white; border-color:#03b6d4;"

    view
    |> element(~s(button[phx-click="toggle_feedback_reason"][phx-value-reason="Too slow"]))
    |> render_click()

    refute render(view) =~ "background:#03b6d4; color:white; border-color:#03b6d4;"

    render_hook(view, "close_feedback_modal", %{})
    refute has_element?(view, "#feedback-modal")
  end
end
