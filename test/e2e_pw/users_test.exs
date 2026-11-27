defmodule Zaq.E2EPw.UsersTest do
  use Zaq.E2EPw.Case

  import Zaq.E2EPw.BO

  @new_user_path "/bo/users/new"

  # BO user form
  setup %{page: page, request: request} do
    reset_e2e_state(request)
    login_to_back_office(page)
    :ok
  end

  test "new user password field shows policy requirements checklist when typing", %{page: page} do
    goto_back_office_live(page, @new_user_path)

    page |> Page.get_by_role(:heading, name: "Create a new user") |> Expect.to_be_visible!()

    password_input = Page.locator(page, "#user-password")
    Locator.fill!(password_input, "Short1!")
    Locator.blur!(password_input)
    wait_for_live_view_settled(page)
    Page.wait_for_timeout!(page, 400)

    panel = Page.locator(page, "#password-requirements")
    Expect.to_be_visible!(panel)
    panel |> Locator.get_by_text("Password Requirements") |> Expect.to_be_visible!()

    page
    |> Page.locator(~s|[id^="password-requirement-"]|)
    |> Locator.first()
    |> Expect.to_be_visible!()
  end
end
