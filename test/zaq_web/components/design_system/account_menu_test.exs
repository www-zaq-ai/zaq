defmodule ZaqWeb.Components.DesignSystem.AccountMenuTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.{AccountMenu, PersonHeader}

  test "blank names fall back safely and Unicode initials retain graphemes" do
    for {name, label, initial} <- [
          {nil, "Profile", "P"},
          {"", "Profile", "P"},
          {" \t\n", "Profile", "P"},
          {" émilie 王 ", "émilie 王", "É"},
          {"👩🏽‍💻 Rivera", "👩🏽‍💻 Rivera", "👩🏽‍💻"}
        ] do
      html = menu(display_name: name)
      assert html =~ "Account menu: #{label}"
      assert html =~ "aria-hidden=\"true\">#{initial}</span>"
    end
  end

  property "Unicode names render safely without injecting markup or changing destinations" do
    check all(name <- string(:utf8, max_length: 80)) do
      html = menu(display_name: "<script>#{name}</script>")
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
      assert html =~ "href=\"/example/profile\""
      assert html =~ "action=\"/example/session\""
    end
  end

  test "caller controls IDs, labels and DELETE logout with CSRF protection" do
    html =
      menu(
        trigger_id: "old-trigger",
        panel_id: "old-panel",
        profile_id: "old-profile",
        logout_form_id: "old-form",
        logout_button_id: "old-button",
        profile_label: "My profile",
        logout_label: "Sign out"
      )

    for id <- ~w(old-trigger old-panel old-profile old-form old-button) do
      assert html =~ "id=\"#{id}\""
    end

    assert html =~ "aria-controls=\"old-panel\""
    assert html =~ "method=\"post\" action=\"/example/session\""
    assert html =~ "name=\"_method\" value=\"delete\""
    assert html =~ "name=\"_csrf_token\""
    assert html =~ "My profile"
    assert html =~ "Sign out"
  end

  test "People composition passes display name through shared avatar presentation" do
    for name <- [nil, "", "Alex Morgan", "王小明"] do
      html = render_component(&PersonHeader.person_header/1, title: "Profile", display_name: name)
      assert html =~ "zaq-account-avatar"
      assert html =~ "Account menu: #{if name in [nil, ""], do: "Profile", else: name}"
      assert html =~ "action=\"/people/session\""
      assert html =~ "href=\"/people/profile\""
      assert html =~ "zaq-account-name hidden sm:inline"
    end
  end

  defp menu(opts) do
    render_component(
      &AccountMenu.account_menu/1,
      Keyword.merge(
        [id: "account", profile_url: "/example/profile", logout_action: "/example/session"],
        opts
      )
    )
  end
end
