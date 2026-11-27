defmodule Zaq.E2EPw.PeopleTest do
  use Zaq.E2EPw.Case

  import Zaq.E2EPw.BO

  @people_path "/bo/people"

  # Mirrors phx-debounce on the people filter inputs (people_live.ex).
  @filter_debounce_ms 300

  @sel %{
    tab_people: ~s|[phx-value-tab="people"]|,
    tab_teams: ~s|[phx-value-tab="teams"]|,
    new_person_button: "#new-person-button",
    save_person_button: "#save-person-button",
    new_team_button: "#new-team-button",
    save_team_button: "#save-team-button",
    team_name_input: ~s|input[name="team[name]"]|,
    add_channel_button: "#add-channel-button",
    save_channel_button: "#save-channel-button",
    modal_overlay: "#people-modal-overlay",

    # Person form fields
    full_name_input: ~s|input[name="person[full_name]"]|,
    email_input: ~s|input[name="person[email]"]|,
    phone_input: ~s|input[name="person[phone]"]|,
    role_input: ~s|input[name="person[role]"]|,

    # Channel form fields
    platform_select: ~s|select[name="channel[platform]"]|,
    channel_identifier_input: ~s|input[name="channel[channel_identifier]"]|,

    # Filters
    filter_name: ~s|input[name="filter_name"]|,
    filter_email: ~s|input[name="filter_email"]|,
    filter_phone: ~s|input[name="filter_phone"]|,
    filter_complete: ~s|select[name="filter_complete"]|,

    # Pagination
    pagination_info: ~s|[data-testid="simple-pagination-range"]|,
    next_page: ~s|button:has-text("Next →")|,
    prev_page: ~s|button:has-text("← Prev")|,

    # Merge
    merge_search_input: ~s|input[name="merge_search"]|,
    confirm_merge_button: ~s|[phx-click="confirm_merge"]|
  }

  # People

  # `let connectorIds` of the spec, set by beforeAll (and by a test that resets, see setup).
  setup_all %{browser: browser} do
    req = APIRequest.new_context!(Playwright.request(BrowserPool.playwright(browser)))

    connector_ids =
      try do
        if reset_state?(), do: reset_e2e_state(req)
        seed_e2e_people_connectors(req)
      after
        APIRequestContext.dispose!(req)
      end

    {:ok, connector_store} = Agent.start(fn -> connector_ids end)
    on_exit(fn -> Agent.stop(connector_store) end)
    %{connector_store: connector_store}
  end

  setup %{page: page, request: request, connector_store: store} = context do
    # Not in the JS, where a test tagged :reset_state ran first after beforeAll's reset: other
    # tests add the teams and grants it expects absent.
    if context[:reset_state] && reset_state?() do
      reset_e2e_state(request)
      Agent.update(store, fn _ -> seed_e2e_people_connectors(request) end)
    end

    login_to_back_office(page)
    goto_back_office_live(page, @people_path)
    %{connector_ids: Agent.get(store, & &1)}
  end

  defp reset_state?, do: System.get_env("E2E_PRESERVE_STATE") != "1"

  defp locator(page, key), do: Page.locator(page, Map.fetch!(@sel, key))
  defp click(page, key), do: page |> locator(key) |> Locator.click!()
  defp fill(page, key, value), do: page |> locator(key) |> Locator.fill!(value)
  defp press(page, key), do: page |> Page.keyboard() |> Keyboard.press!(key)

  defp expect_modal_closed(page),
    do: page |> locator(:modal_overlay) |> Expect.not_() |> Expect.to_be_visible!()

  # Navigation

  @tag timeout: 120_000
  @tag :reset_state
  test "permissions persist independent global and team grants with keyboard and mobile scrolling",
       %{page: page} do
    page |> Page.locator(~s|[phx-value-tab="permissions"]|) |> Locator.click!()
    # Reset leaves no user-created teams; the existing Everyone system team remains.
    page
    |> Page.locator("#people-permissions-table thead th")
    |> Expect.to_have_text!(["Permission", "Everyone"])

    page
    |> Page.locator(~s|#people-permissions-table input[aria-checked="true"]|)
    |> Expect.to_have_count!(0)

    page
    |> Page.locator("#people-permissions-table tbody th")
    |> Expect.to_have_text!([
      "Access profile",
      "Edit profile",
      "Manage credentials",
      "Access message history",
      "Share conversations"
    ])

    click(page, :tab_teams)

    team_names =
      for n <- 0..4 do
        "Permissions #{System.system_time(:millisecond)} #{n} very long team name for responsive layout"
      end

    for name <- team_names do
      click(page, :new_team_button)
      fill(page, :team_name_input, name)
      click(page, :save_team_button)
      expect_modal_closed(page)
    end

    page |> Page.locator(~s|[phx-value-tab="permissions"]|) |> Locator.click!()
    global_profile = Page.locator(page, "#permission-everyone-access_profile")
    global_history = Page.locator(page, "#permission-everyone-access_message_history")
    global_edit = Page.locator(page, "#permission-everyone-edit_profile")
    global_edit |> Locator.locator("..") |> Locator.click!()
    Expect.to_have_attribute!(global_edit, "aria-checked", "true")
    global_profile |> Expect.not_() |> Expect.to_be_checked!()

    team_share =
      Page.get_by_role(page, :switch, name: ~r/Share conversations — #{Enum.at(team_names, 0)}/)

    global_profile |> Expect.not_() |> Expect.to_be_checked!()
    Locator.focus!(global_profile)
    Expect.to_be_focused!(global_profile)
    press(page, "Space")
    Expect.to_have_attribute!(global_profile, "aria-checked", "true")
    Expect.to_be_checked!(global_profile)

    assert Locator.evaluate!(
             global_profile,
             "input => getComputedStyle(input.nextElementSibling).outlineStyle"
           ) == "solid"

    team_share |> Locator.locator("..") |> Locator.click!()
    Expect.to_have_attribute!(team_share, "aria-checked", "true")
    global_history |> Expect.not_() |> Expect.to_be_checked!()

    team_history =
      Page.get_by_role(page, :switch,
        name: ~r/Access message history — #{Enum.at(team_names, 0)}/
      )

    team_history |> Expect.not_() |> Expect.to_be_checked!()
    Page.reload!(page)
    wait_for_server_round_trip(page)
    page |> Page.locator(~s|[phx-value-tab="permissions"]|) |> Locator.click!()
    Expect.to_be_checked!(global_profile)
    Expect.to_be_checked!(team_share)
    Expect.to_be_checked!(global_edit)
    team_history |> Expect.not_() |> Expect.to_be_checked!()
    global_profile |> Locator.locator("..") |> Locator.click!()
    Expect.to_have_attribute!(global_profile, "aria-checked", "false")
    Expect.to_be_checked!(team_share)
    Page.screenshot!(page, path: Test.output_path("people-permissions-desktop.png"))

    Page.set_viewport_size!(page, %{width: 390, height: 844})
    page |> Page.locator("#sidebar-toggle") |> Locator.click!()
    page |> Page.locator("#bo-sidebar") |> Expect.to_have_class!(~r/collapsed/)

    Expect.poll!(
      fn ->
        page
        |> Page.locator("#bo-sidebar")
        |> Locator.evaluate!("sidebar => Math.round(sidebar.getBoundingClientRect().width)")
      end,
      &assert(&1 == 60)
    )

    Page.evaluate!(page, "() => window.scrollTo(0, 0)")
    # The existing BO header has its own minimum width. The matrix must remain
    # inside the viewport and must not add to that existing shell overflow.
    shell_width =
      page
      |> Page.locator("#bo-main > header")
      |> Locator.evaluate!(
        "header => Math.ceil(header.getBoundingClientRect().left + window.scrollX + header.scrollWidth)"
      )

    dimensions =
      page
      |> Page.locator("#people-permissions-table")
      |> Locator.evaluate!("""
      table => ({
        scroll: table.parentElement.scrollWidth,
        width: table.parentElement.clientWidth,
        viewport: document.documentElement.clientWidth,
        document: document.documentElement.scrollWidth,
        right: table.parentElement.getBoundingClientRect().right,
        left: table.parentElement.getBoundingClientRect().left,
      })
      """)

    assert dimensions["scroll"] > dimensions["width"]
    assert dimensions["right"] <= dimensions["viewport"]
    assert dimensions["left"] >= 0
    assert dimensions["width"] > 200
    assert dimensions["document"] <= shell_width

    page
    |> Page.locator("#people-permissions-table")
    |> Locator.evaluate!(
      "table => { table.parentElement.scrollLeft = table.parentElement.scrollWidth }"
    )

    Expect.poll!(
      fn ->
        page
        |> Page.locator("#people-permissions-table")
        |> Locator.evaluate!("table => table.parentElement.scrollLeft")
      end,
      &assert(&1 > 0)
    )

    Page.evaluate!(page, "() => window.scrollTo(0, 0)")
    page |> Page.locator("#people-permissions-table") |> Expect.to_be_visible!()
    Page.screenshot!(page, path: Test.output_path("people-permissions-mobile.png"))
    Locator.focus!(global_history)
    press(page, "Space")
    Expect.to_have_attribute!(global_history, "aria-checked", "true")
  end

  for granted <- [true, false] do
    # A tag, not a module attribute: a literal makes the compiler flag one `if` branch as dead.
    @tag granted: granted
    test "reconciles native permission checkbox after rejected #{if granted, do: "revoke", else: "grant"} with unchanged authority",
         %{page: page, granted: granted} do
      page |> Page.locator(~s|[phx-value-tab="permissions"]|) |> Locator.click!()
      control = Page.locator(page, "#permission-everyone-access_profile")

      if Locator.is_checked!(control) != granted do
        control |> Locator.locator("..") |> Locator.click!()
        Expect.to_have_attribute!(control, "aria-checked", to_string(granted))
      end

      # Change only the outgoing permission. Keep the real native click, valid
      # scope and desired boolean; the canonical write boundary must reject it.
      Locator.evaluate!(control, """
      input => {
        const commands = JSON.parse(input.getAttribute("phx-click"))
        commands.find(([command]) => command === "push")[1].value.permission = "unknown_permission"
        input.setAttribute("phx-click", JSON.stringify(commands))
        input.addEventListener("click", () => { window.permissionNativeChecked = input.checked }, { once: true })
      }
      """)

      control |> Locator.locator("..") |> Locator.click!()
      assert Page.evaluate!(page, "() => window.permissionNativeChecked") == not granted
      # This is the mutation error branch, not the malformed browser-state branch.
      page |> Page.locator("#flash-error") |> Expect.to_contain_text!("Permission change failed")
      Expect.to_be_checked!(control, checked: granted)
      Expect.to_have_attribute!(control, "aria-checked", to_string(granted))

      Page.reload!(page)
      wait_for_server_round_trip(page)
      page |> Page.locator(~s|[phx-value-tab="permissions"]|) |> Locator.click!()
      Expect.to_be_checked!(control, checked: granted)
      Expect.to_have_attribute!(control, "aria-checked", to_string(granted))

      if granted do
        control |> Locator.locator("..") |> Locator.click!()
        Expect.to_have_attribute!(control, "aria-checked", "false")
      end
    end
  end

  test "reconciles native permission checkbox after malformed and no-op attempts", %{page: page} do
    page |> Page.locator(~s|[phx-value-tab="permissions"]|) |> Locator.click!()
    control = Page.locator(page, "#permission-everyone-access_profile")

    for granted <- [false, true] do
      if Locator.is_checked!(control) != granted do
        control |> Locator.locator("..") |> Locator.click!()
        Expect.to_have_attribute!(control, "aria-checked", to_string(granted))
      end

      original = Locator.get_attribute!(control, "phx-click")

      for payload <- [%{enabled: granted}, %{enabled: "false"}, %{scope: "person-1"}] do
        attempt_permission_payload(page, control, original, payload, granted)
      end

      Page.reload!(page)
      wait_for_server_round_trip(page)
      page |> Page.locator(~s|[phx-value-tab="permissions"]|) |> Locator.click!()
      Expect.to_be_checked!(control, checked: granted)
    end

    control |> Locator.locator("..") |> Locator.click!()
    Expect.to_have_attribute!(control, "aria-checked", "false")
  end

  defp attempt_permission_payload(page, control, original, payload, granted) do
    Locator.evaluate!(
      control,
      """
      (input, { original, payload }) => {
        const commands = JSON.parse(original)
        Object.assign(commands.find(([command]) => command === "push")[1].value, payload)
        input.setAttribute("phx-click", JSON.stringify(commands))
        input.addEventListener("click", () => { window.permissionNativeChecked = input.checked }, { once: true })
      }
      """,
      %{original: original, payload: payload}
    )

    control |> Locator.locator("..") |> Locator.click!()
    assert Page.evaluate!(page, "() => window.permissionNativeChecked") == not granted
    wait_for_server_round_trip(page)
    Expect.to_be_checked!(control, checked: granted)
    Expect.to_have_attribute!(control, "aria-checked", to_string(granted))

    if is_binary(payload[:enabled]) or payload[:scope] do
      page |> Page.locator("#flash-error") |> Expect.to_contain_text!("Invalid permission change")
    end
  end

  test "registers only the People opt-ins alongside existing app hooks", %{page: page} do
    registered = Page.evaluate!(page, "() => Object.keys(window.liveSocket.hooks)")

    assert Enum.sort(registered) ==
             Enum.sort([
               "AutoExpand",
               "ChartTooltip",
               "ContentFilter",
               "CopyToClipboard",
               "CronCountdown",
               "DetailsKeepOpen",
               "DownloadFile",
               "FlashAutoDismiss",
               "FocusAndSelect",
               "FocusInput",
               "FolderDrop",
               "JsonTree",
               "LoadingActionButton",
               "MarkdownHighlight",
               "OAuthPopupListener",
               "OntologyTree",
               "PeopleAuthForm",
               "PeopleBulkDeleteDialog",
               "PeopleOTP",
               "PeoplePermissions",
               "ScrollBottom",
               "ScrollToFirstError",
               "SearchableSelect",
               "ToolStepTimer",
               "WorkflowExport",
               "ZaqWeb.Components.DesignSystem.AccountMenu.AccountDisclosure",
               "ZaqWeb.Components.DesignSystem.ChannelPriorityList.PriorityDrag",
               "ZaqWeb.Components.DesignSystem.Checkbox.MixedCheckbox",
               "ZaqWeb.Components.DesignSystem.ModelModalities.ModalityTooltips",
               "ZaqWeb.Components.DesignSystem.PersonProfile.ProfileFocus",
               "liveViewHooks"
             ])

    refute "DetectTimezone" in registered
    refute "DialogOverlay" in registered
  end

  @tag timeout: 120_000
  test "cross-page selection supports keyboard, mixed state and scoped deletion", %{page: page} do
    prefix = "Selection #{System.system_time(:millisecond)}"

    for n <- 1..23 do
      click(page, :new_person_button)
      fill(page, :full_name_input, "#{prefix} #{String.pad_leading(to_string(n), 2, "0")}")
      click(page, :save_person_button)
      expect_modal_closed(page)
    end

    fill(page, :filter_name, prefix)
    page |> locator(:pagination_info) |> Expect.to_have_text!("1–20 of 23")
    selection = Page.locator(page, "#people-selection")
    page_checkbox = Page.get_by_role(page, :checkbox, name: "Select current page")

    first_row_checkbox =
      page |> Page.locator("#people-table input[type=checkbox]") |> Locator.first()

    Locator.focus!(first_row_checkbox)
    press(page, "Space")
    Expect.to_contain_text!(selection, "1 selected")
    page |> Page.locator(~s|[phx-click="deselect_person"]|) |> Expect.to_have_count!(0)
    Expect.to_have_attribute!(page_checkbox, "aria-checked", "mixed")
    Expect.to_have_js_property!(page_checkbox, "indeterminate", true)
    Locator.focus!(page_checkbox)
    press(page, "Space")
    Expect.to_contain_text!(selection, "20 selected")
    Expect.to_have_js_property!(page_checkbox, "indeterminate", false)
    click(page, :next_page)
    page |> locator(:pagination_info) |> Expect.to_have_text!("21–23 of 23")
    Expect.to_contain_text!(selection, "20 selected")
    page_checkbox |> Expect.not_() |> Expect.to_be_checked!()
    click(page, :prev_page)
    Expect.to_be_checked!(page_checkbox)
    page |> Page.locator("#people-selection-all") |> Locator.click!()
    Expect.to_contain_text!(selection, "23 selected")
    click(page, :next_page)
    page |> locator(:pagination_info) |> Expect.to_have_text!("21–23 of 23")

    page
    |> Page.locator("#people-table input[type=checkbox]")
    |> Locator.last()
    |> Locator.click!()

    Expect.to_contain_text!(selection, "22 selected")
    Expect.to_have_js_property!(page_checkbox, "indeterminate", true)
    page |> Page.locator(~s|[phx-click="deselect_person"]|) |> Expect.to_have_count!(0)
    page |> Page.locator("#bulk-delete-button") |> Locator.click!()
    dialog = Page.get_by_role(page, :dialog, name: "Delete selected people")
    Expect.to_contain_text!(dialog, "Delete 22 selected people?")
    press(page, "Escape")
    dialog |> Expect.not_() |> Expect.to_be_visible!()
    page |> Page.locator("#bulk-delete-button") |> Expect.to_be_focused!()
    page |> Page.locator("#bulk-delete-button") |> Locator.click!()
    page |> Page.locator("#confirm-people-bulk-delete") |> Locator.click!()
    page |> locator(:pagination_info) |> Expect.to_have_text!("1–1 of 1")
    page |> Page.locator("#people-table tbody") |> Expect.to_contain_text!("#{prefix} 23")
    Locator.check!(page_checkbox)
    fill(page, :filter_name, "no-matches-for-selection")
    page |> Page.locator("#people-table") |> Expect.to_have_count!(0)
    page |> Page.locator("#bulk-delete-button") |> Expect.to_have_count!(0)
  end

  test "default tab is People", %{page: page} do
    page |> locator(:tab_people) |> Expect.to_be_visible!()
    page |> locator(:new_person_button) |> Expect.to_be_visible!()
  end

  test "master-detail layout shell is present on people page", %{page: page} do
    page |> Page.locator(~s|[data-testid="bo-master-detail-layout"]|) |> Expect.to_be_visible!()
    page |> Page.locator("#people-master-pane") |> Expect.to_be_visible!()
  end

  test "switching to Teams tab shows New Team button", %{page: page} do
    click(page, :tab_teams)
    page |> Page.locator("#new-team-button") |> Expect.to_be_visible!()
    page |> locator(:new_person_button) |> Expect.not_() |> Expect.to_be_visible!()
  end

  # Create person

  test "creates a new complete person and shows them in the list", %{page: page} do
    ts = System.system_time(:millisecond)
    name = "E2E Person #{ts}"

    click(page, :new_person_button)
    page |> locator(:modal_overlay) |> Expect.to_be_visible!()

    fill(page, :full_name_input, name)
    fill(page, :email_input, "#{ts}@example.com")
    fill(page, :phone_input, "+1 555 000 0001")

    click(page, :save_person_button)
    expect_modal_closed(page)

    filter_by_name(page, "#{ts}")
    page |> Page.get_by_text(name) |> Expect.to_be_visible!()
  end

  test "creates an incomplete person (no phone) and shows incomplete badge", %{page: page} do
    ts = System.system_time(:millisecond)
    name = "E2E Incomplete #{ts}"

    click(page, :new_person_button)
    fill(page, :full_name_input, name)
    fill(page, :email_input, "incomplete-#{ts}@example.com")
    # No phone → stays incomplete

    click(page, :save_person_button)
    expect_modal_closed(page)

    filter_by_name(page, "#{ts}")

    # Select the person to verify incomplete badge in detail panel
    page |> Page.get_by_text(name) |> Locator.click!()
    page |> Page.locator(~s|[phx-click="deselect_person"]|) |> Expect.to_be_visible!()
    # Incomplete badge appears in status cell
    page
    |> Page.locator(".bg-amber-100", has_text: "incomplete")
    |> Locator.first()
    |> Expect.to_be_visible!()
  end

  # Merge flow

  test "normalizes mixed-case email on create and edit, survives reload, and rejects duplicates",
       %{page: page} do
    ts = System.system_time(:millisecond)
    name = "E2E Canonical #{ts}"
    other_name = "E2E Other #{ts}"
    canonical = "canonical-#{ts}@example.com"
    edited = "edited-#{ts}@example.com"

    edit_person =
      ~s|[phx-click="open_modal"][phx-value-action="edit"][phx-value-entity="person"]|

    click(page, :new_person_button)
    wait_for_live_view_settled(page)
    fill(page, :full_name_input, name)
    fill(page, :email_input, "Canonical-#{ts}@EXAMPLE.COM")
    click(page, :save_person_button)
    expect_modal_closed(page)

    goto_back_office_live(page, @people_path)
    # A matching row can exist before filtering. Wait for the filtered table
    # before clicking: blur flushes the debounce and can patch during the click.
    filter_by_name(page, name)
    expect_single_row(page, name)
    select_person(page, name)
    page |> Page.locator(edit_person) |> Locator.first() |> Locator.click!()
    page |> locator(:email_input) |> Expect.to_have_value!(canonical)
    fill(page, :email_input, "Edited-#{ts}@EXAMPLE.COM")
    click(page, :save_person_button)
    expect_modal_closed(page)

    Page.reload!(page)
    wait_for_live_view_connected(page)
    wait_for_live_view_settled(page)
    filter_by_name(page, name)
    expect_single_row(page, name)
    select_person(page, name)
    page |> Page.locator(edit_person) |> Locator.first() |> Locator.click!()
    page |> locator(:email_input) |> Expect.to_have_value!(edited)

    goto_back_office_live(page, @people_path)
    click(page, :new_person_button)
    wait_for_live_view_settled(page)
    fill(page, :full_name_input, other_name)
    fill(page, :email_input, "EDITED-#{ts}@Example.com")
    click(page, :save_person_button)
    page |> locator(:modal_overlay) |> Expect.to_contain_text!("has already been taken")

    # Correct the rejected create, then attempt the same collision through edit.
    fill(page, :email_input, "other-#{ts}@example.com")
    click(page, :save_person_button)
    expect_modal_closed(page)
    filter_by_name(page, other_name)
    expect_single_row(page, other_name)
    select_person(page, other_name)
    page |> Page.locator(edit_person) |> Locator.first() |> Locator.click!()
    fill(page, :email_input, "EDITED-#{ts}@Example.com")
    click(page, :save_person_button)
    page |> locator(:modal_overlay) |> Expect.to_contain_text!("has already been taken")

    goto_back_office_live(page, @people_path)
    filter_by_name(page, other_name)
    expect_single_row(page, other_name)
    select_person(page, other_name)
    page |> Page.locator(edit_person) |> Locator.first() |> Locator.click!()
    page |> locator(:email_input) |> Expect.to_have_value!("other-#{ts}@example.com")
  end

  defp expect_single_row(page, name) do
    page |> Page.locator("#people-table tbody tr") |> Expect.to_have_count!(1)

    page
    |> Page.locator("#people-table tbody tr")
    |> Locator.filter(has_text: name)
    |> Expect.to_have_count!(1)
  end

  test "merge modal opens from detail panel Merge button", %{page: page} do
    ts = System.system_time(:millisecond)
    name_a = "E2E MergeA #{ts}"
    name_b = "E2E MergeB #{ts}"

    # Create person A
    click(page, :new_person_button)
    fill(page, :full_name_input, name_a)
    click(page, :save_person_button)
    expect_modal_closed(page)

    # Create person B
    click(page, :new_person_button)
    fill(page, :full_name_input, name_b)
    click(page, :save_person_button)
    expect_modal_closed(page)

    filter_by_name(page, "#{ts}")

    # Select person A → open merge modal
    select_person(page, name_a)

    page
    |> Page.locator(~s|[phx-click="open_merge_modal"]|)
    |> Locator.first()
    |> Locator.click!()

    page |> locator(:modal_overlay) |> Expect.to_be_visible!()
    page |> Page.get_by_text("Merge Persons") |> Expect.to_be_visible!()
    page |> Page.get_by_text("Survivor (kept)", exact: false) |> Expect.to_be_visible!()
    page |> locator(:merge_search_input) |> Expect.to_be_visible!()
  end

  test "merge keeps selected survivor, channels and teams and displays merged identity history",
       %{page: page, connector_ids: connector_ids} do
    ts = System.system_time(:millisecond)
    name_survivor = "E2E Survivor #{ts}"
    name_loser = "E2E Loser #{ts}"
    loser_email = "merge-loser-#{ts}@example.com"

    email_channel =
      page
      |> Page.locator("#people-detail-pane")
      |> Locator.get_by_text("email", exact: true)
      |> Locator.locator("..")

    team_name = "Merge team #{ts}"

    click(page, :tab_teams)
    click(page, :new_team_button)
    fill(page, :team_name_input, team_name)
    click(page, :save_team_button)
    expect_modal_closed(page)
    click(page, :tab_people)
    wait_for_live_view_settled(page)

    # Create survivor
    click(page, :new_person_button)
    fill(page, :full_name_input, name_survivor)
    click(page, :save_person_button)
    expect_modal_closed(page)

    # Create loser
    click(page, :new_person_button)
    fill(page, :full_name_input, name_loser)
    fill(page, :email_input, loser_email)
    click(page, :save_person_button)
    expect_modal_closed(page)

    # Filter to just these two people so they're visible regardless of page
    filter_by_name(page, "#{ts}")
    page |> Page.get_by_text(name_survivor) |> Expect.to_be_visible!()

    select_person(page, name_loser)

    loser_id =
      page
      |> Page.locator(~s|#people-detail-pane [phx-click="open_merge_modal"]|)
      |> Locator.get_attribute!("phx-value-id")

    pick_searchable_select(page, ~s|[id^="team-select-#{loser_id}-"]|, team_name)
    wait_for_live_view_settled(page)
    click(page, :add_channel_button)
    select_person_channel_connector(page, "telegram", connector_ids["telegram"])
    fill(page, :channel_identifier_input, "merge-channel-#{ts}")
    click(page, :save_channel_button)
    expect_modal_closed(page)

    # Select survivor → open merge modal
    select_person(page, name_survivor)
    click(page, :add_channel_button)
    select_person_channel_connector(page, "email", connector_ids["email"])
    fill(page, :channel_identifier_input, " MERGE-LOSER-#{ts}@EXAMPLE.COM ")
    click(page, :save_channel_button)

    page
    |> Page.locator("#channel-modal-form")
    |> Expect.to_contain_text!("This channel identifier is already assigned.")

    page |> locator(:channel_identifier_input) |> Expect.to_have_value!(loser_email)

    page
    |> Page.locator("#channel-modal-form")
    |> Locator.get_by_role(:button, name: "Cancel", exact: true)
    |> Locator.click!()

    expect_modal_closed(page)
    Expect.to_have_count!(email_channel, 0)

    page
    |> Page.locator("#people-detail-pane")
    |> Expect.not_()
    |> Expect.to_contain_text!("MERGE-LOSER-#{ts}@EXAMPLE.COM")

    page
    |> Page.locator(~s|[phx-click="open_merge_modal"]|)
    |> Locator.first()
    |> Locator.click!()

    page |> locator(:modal_overlay) |> Expect.to_be_visible!()

    # Search for loser
    fill(page, :merge_search_input, "E2E Loser #{ts}")
    # Wait for candidate to appear and click it
    page
    |> Page.locator(~s|[phx-click="select_merge_loser"]|)
    |> Locator.first()
    |> Locator.click!()

    # Confirm merge button should appear
    page |> locator(:confirm_merge_button) |> Expect.to_be_visible!()

    expect_flash_during_action(page, "Persons merged successfully", fn ->
      click(page, :confirm_merge_button)
    end)

    # Modal closes, success flash
    expect_modal_closed(page)

    # Loser no longer in people list
    page
    |> Page.locator("#people-table")
    |> Locator.get_by_text(name_loser)
    |> Expect.not_()
    |> Expect.to_be_visible!()

    page |> Page.locator("#people-detail-pane") |> Expect.to_contain_text!(team_name)
    page |> Page.locator("#people-detail-pane") |> Expect.to_contain_text!("merge-channel-#{ts}")
    email_channel |> Locator.locator("p") |> Locator.first() |> Expect.to_have_text!(loser_email)

    page
    |> Page.locator("#people-detail-pane")
    |> Locator.get_by_text("email", exact: true)
    |> Expect.to_have_count!(1)

    page |> Page.locator("#person-merged-entries") |> Expect.to_contain_text!(name_loser)

    page
    |> Page.locator("#person-merged-entries")
    |> Expect.not_()
    |> Expect.to_contain_text!(loser_email)

    page |> Page.locator("#person-merged-entries") |> Expect.to_contain_text!(loser_id)
    goto_back_office_live(page, "#{@people_path}?person_id=#{loser_id}")

    page
    |> Page.locator("#people-detail-pane h3")
    |> Locator.first()
    |> Expect.to_have_text!(name_survivor)

    page
    |> Page.locator("#people-detail-pane")
    |> Locator.get_by_text("email", exact: true)
    |> Expect.to_have_count!(1)

    email_channel |> Locator.locator("p") |> Locator.first() |> Expect.to_have_text!(loser_email)
    page |> Page.locator("#person-merged-entries") |> Expect.to_contain_text!(name_loser)
  end

  # Channel management

  for platform <- ["email", "telegram"], same_person <- [true, false] do
    @platform platform
    @same_person same_person

    test "#{platform} add/edit duplicate errors retain values (#{if same_person, do: "same", else: "cross"} person)",
         %{page: page, connector_ids: connector_ids} do
      platform = @platform
      ts = System.system_time(:millisecond)
      owner = "E2E Owner #{ts}"
      target = if @same_person, do: owner, else: "E2E Target #{ts}"
      identifier = "identity-#{ts}@example.com"

      for name <- Enum.uniq([owner, target]) do
        click(page, :new_person_button)
        fill(page, :full_name_input, name)
        click(page, :save_person_button)
        expect_modal_closed(page)
      end

      filter_by_name(page, "#{ts}")
      select_person(page, owner)
      click(page, :add_channel_button)
      select_person_channel_connector(page, platform, connector_ids[platform])
      fill(page, :channel_identifier_input, identifier)
      click(page, :save_channel_button)
      expect_modal_closed(page)
      select_person(page, target)
      click(page, :add_channel_button)
      select_person_channel_connector(page, platform, connector_ids[platform])
      duplicate = if platform == "email", do: " #{String.upcase(identifier)} ", else: identifier
      fill(page, :channel_identifier_input, duplicate)
      click(page, :save_channel_button)

      page
      |> Page.locator("#channel-modal-form")
      |> Expect.to_contain_text!("This channel identifier is already assigned.")

      page |> locator(:channel_identifier_input) |> Expect.to_have_value!(identifier)
      page |> locator(:platform_select) |> Expect.to_have_value!(platform)
      editable = "editable-#{ts}@example.com"
      fill(page, :channel_identifier_input, editable)
      click(page, :save_channel_button)
      expect_modal_closed(page)

      channel_row =
        page
        |> Page.locator("#people-detail-pane")
        |> Locator.get_by_text(editable, exact: true)
        |> Locator.locator("../..")

      channel_row
      |> Locator.locator(
        ~s|[phx-click="open_modal"][phx-value-entity="channel"][phx-value-action="edit"]|
      )
      |> Locator.click!()

      fill(page, :channel_identifier_input, duplicate)
      click(page, :save_channel_button)

      page
      |> Page.locator("#channel-modal-form")
      |> Expect.to_contain_text!("This channel identifier is already assigned.")

      page |> locator(:channel_identifier_input) |> Expect.to_have_value!(identifier)
      fill(page, :channel_identifier_input, "corrected-#{ts}@example.com")
      click(page, :save_channel_button)
      expect_modal_closed(page)

      page
      |> Page.locator("#people-detail-pane")
      |> Expect.to_contain_text!("corrected-#{ts}@example.com")
    end
  end

  test "platform dropdown includes telegram and discord", %{page: page} do
    # Create a person first so the detail panel and Add Channel button are accessible
    name = "E2E ChanPlatform #{System.system_time(:millisecond)}"
    click(page, :new_person_button)
    fill(page, :full_name_input, name)
    click(page, :save_person_button)
    expect_modal_closed(page)

    filter_by_name(page, name)
    person_row = page |> Page.get_by_text(name) |> Locator.first()
    Expect.to_be_visible!(person_row)
    select_person(page, name)
    click(page, :add_channel_button)
    page |> locator(:modal_overlay) |> Expect.to_be_visible!()

    options =
      page |> Page.locator("#{@sel.platform_select} option") |> Locator.all_text_contents!()

    assert "Telegram" in options
    assert "Discord" in options

    values =
      page
      |> Page.locator("#{@sel.platform_select} option")
      |> Locator.evaluate_all!("options => options.map(option => option.value)")

    assert "telegram" in values
    assert "discord" in values
  end

  # Filtering

  test "filter by name narrows results", %{page: page} do
    ts = System.system_time(:millisecond)
    name_a = "E2E FilterA #{ts}"
    name_b = "E2E FilterB #{ts}"

    click(page, :new_person_button)
    fill(page, :full_name_input, name_a)
    click(page, :save_person_button)
    expect_modal_closed(page)

    click(page, :new_person_button)
    fill(page, :full_name_input, name_b)
    click(page, :save_person_button)
    expect_modal_closed(page)

    filter_by_name(page, name_a)
    page |> Page.get_by_text(name_a) |> Expect.to_be_visible!()
    page |> Page.get_by_text(name_b) |> Expect.not_() |> Expect.to_be_visible!()
  end

  test "filter by email narrows results", %{page: page} do
    ts = System.system_time(:millisecond)
    name = "E2E FilterEmail #{ts}"
    email = "filter-email-#{ts}@example.com"

    click(page, :new_person_button)
    fill(page, :full_name_input, name)
    fill(page, :email_input, email)
    click(page, :save_person_button)
    expect_modal_closed(page)

    fill(page, :filter_email, "filter-email-#{ts}")
    page |> Page.get_by_text(name) |> Expect.to_be_visible!()
  end

  test "filter by complete status shows only complete people", %{page: page} do
    ts = System.system_time(:millisecond)
    complete_name = "E2E Complete #{ts}"
    incomplete_name = "E2E Incomplete #{ts}"

    # Complete requires full_name + email + phone
    click(page, :new_person_button)
    fill(page, :full_name_input, complete_name)
    fill(page, :email_input, "complete-#{ts}@example.com")
    fill(page, :phone_input, "+1 555 000 0099")
    click(page, :save_person_button)
    expect_modal_closed(page)

    # Incomplete person (no phone)
    click(page, :new_person_button)
    fill(page, :full_name_input, incomplete_name)
    click(page, :save_person_button)
    expect_modal_closed(page)

    filter_by_name(page, "#{ts}")
    page |> locator(:filter_complete) |> Locator.select_option!("complete")
    page |> Page.get_by_text(complete_name) |> Expect.to_be_visible!()
    page |> Page.get_by_text(incomplete_name) |> Expect.not_() |> Expect.to_be_visible!()
  end

  test "filter by incomplete status shows only incomplete people", %{page: page} do
    ts = System.system_time(:millisecond)
    complete_name = "E2E CmpFull #{ts}"
    incomplete_name = "E2E IncFull #{ts}"

    # Complete requires full_name + email + phone
    click(page, :new_person_button)
    fill(page, :full_name_input, complete_name)
    fill(page, :email_input, "cmpfull-#{ts}@example.com")
    fill(page, :phone_input, "+1 555 000 0088")
    click(page, :save_person_button)
    expect_modal_closed(page)

    click(page, :new_person_button)
    fill(page, :full_name_input, incomplete_name)
    click(page, :save_person_button)
    expect_modal_closed(page)

    filter_by_name(page, "#{ts}")
    page |> locator(:filter_complete) |> Locator.select_option!("incomplete")
    page |> Page.get_by_text(incomplete_name) |> Expect.to_be_visible!()
    page |> Page.get_by_text(complete_name) |> Expect.not_() |> Expect.to_be_visible!()
  end

  test "clearing filters restores full list", %{page: page} do
    ts = System.system_time(:millisecond)
    name = "E2E ClearFilter #{ts}"

    click(page, :new_person_button)
    fill(page, :full_name_input, name)
    click(page, :save_person_button)
    expect_modal_closed(page)

    filter_by_name(page, "zzz-no-match")
    page |> Page.get_by_text(name) |> Expect.not_() |> Expect.to_be_visible!()

    # Clear no-match filter and re-filter by unique ts — person must be visible again
    filter_by_name(page, "#{ts}")
    page |> Page.get_by_text(name) |> Expect.to_be_visible!()
  end

  # Pagination

  test "pagination info shows range and total when people exist", %{page: page} do
    name = "E2E PagInfo #{System.system_time(:millisecond)}"

    click(page, :new_person_button)
    fill(page, :full_name_input, name)
    click(page, :save_person_button)
    expect_modal_closed(page)

    # e.g. "1–5 of 5"
    page
    |> locator(:pagination_info)
    |> Locator.filter(has_text: "of")
    |> Locator.first()
    |> Expect.to_be_visible!()
  end

  test "next/prev buttons absent when filtered results fit on one page", %{page: page} do
    ts = System.system_time(:millisecond)
    name = "E2E PagSingle #{ts}"

    click(page, :new_person_button)
    fill(page, :full_name_input, name)
    click(page, :save_person_button)
    expect_modal_closed(page)

    # Filter to exactly this one person
    filter_by_name(page, "#{ts}")
    page |> Page.get_by_text(name) |> Expect.to_be_visible!()

    page |> locator(:next_page) |> Expect.not_() |> Expect.to_be_visible!()
    page |> locator(:prev_page) |> Expect.not_() |> Expect.to_be_visible!()
  end

  # Teams

  test "team created in Teams tab can be assigned to person and used as filter", %{page: page} do
    ts = System.system_time(:millisecond)
    team_name = "Team #{ts}"
    person_name = "E2E TeamFilter #{ts}"

    # Create team from Teams tab
    click(page, :tab_teams)
    click(page, :new_team_button)
    fill(page, :team_name_input, team_name)
    click(page, :save_team_button)
    expect_modal_closed(page)
    page |> Page.get_by_text(team_name) |> Expect.to_be_visible!()

    # Create person from People tab
    click(page, :tab_people)
    click(page, :new_person_button)
    fill(page, :full_name_input, person_name)
    click(page, :save_person_button)
    expect_modal_closed(page)

    # Filter to person and select them
    filter_by_name(page, "#{ts}")
    select_person(page, person_name)

    # Assign team from detail panel
    pick_searchable_select(page, ~s|form[phx-change="assign_team_select"]|, team_name)
    page |> team_badge(team_name) |> Expect.to_be_visible!()

    # Filter by team — person should appear in the list
    filter_by_name(page, "")
    pick_searchable_select(page, "#filter-team-select", team_name)
    page |> Page.get_by_text(person_name) |> Locator.first() |> Expect.to_be_visible!()
  end

  test "team can be created inline from person detail panel", %{page: page} do
    ts = System.system_time(:millisecond)
    team_name = "Inline Team #{ts}"
    person_name = "E2E InlineTeam #{ts}"

    # Create person and select them
    click(page, :new_person_button)
    fill(page, :full_name_input, person_name)
    click(page, :save_person_button)
    expect_modal_closed(page)

    filter_by_name(page, "#{ts}")
    select_person(page, person_name)

    # Open the team assign select, type a new team name, hit Create
    create_and_assign_team(page, team_name)

    # Team badge appears on the person
    page |> team_badge(team_name) |> Expect.to_be_visible!()
  end

  test "merging persons unions their teams onto the survivor", %{page: page} do
    ts = System.system_time(:millisecond)
    survivor_name = "E2E TeamSurvivor #{ts}"
    loser_name = "E2E TeamLoser #{ts}"
    team_a = "TeamA #{ts}"
    team_b = "TeamB #{ts}"

    # Create both people
    click(page, :new_person_button)
    fill(page, :full_name_input, survivor_name)
    click(page, :save_person_button)
    expect_modal_closed(page)

    click(page, :new_person_button)
    fill(page, :full_name_input, loser_name)
    click(page, :save_person_button)
    expect_modal_closed(page)

    # Assign teamA to survivor
    filter_by_name(page, "#{ts}")
    select_person(page, survivor_name)
    create_and_assign_team(page, team_a)
    page |> team_badge(team_a) |> Expect.to_be_visible!()

    # Assign teamB to loser
    select_person(page, loser_name)
    create_and_assign_team(page, team_b)
    page |> team_badge(team_b) |> Expect.to_be_visible!()

    # Merge loser into survivor
    select_person(page, survivor_name)

    page
    |> Page.locator(~s|[phx-click="open_merge_modal"]|)
    |> Locator.first()
    |> Locator.click!()

    page |> locator(:modal_overlay) |> Expect.to_be_visible!()

    fill(page, :merge_search_input, loser_name)

    page
    |> Page.locator(~s|[phx-click="select_merge_loser"]|)
    |> Locator.first()
    |> Locator.click!()

    expect_flash_during_action(page, "Persons merged successfully", fn ->
      click(page, :confirm_merge_button)
    end)

    expect_modal_closed(page)

    # Survivor should now carry both teams (detail panel already open)
    select_person(page, survivor_name)
    page |> team_badge(team_a) |> Expect.to_be_visible!()
    page |> team_badge(team_b) |> Expect.to_be_visible!()
  end

  # Helpers

  # The filter inputs carry phx-debounce="300", so the LiveView patch lands up to
  # ~300ms after .fill() has already resolved. Acting on the list inside that
  # window silently loses the interaction: morphdom is re-keying #people-table's
  # tbody, and LiveView's delegated handler resolves the click target after the
  # row node was detached, so the phx-click is dropped with no error. Outlast the
  # debounce, then wait for the resulting round trip to finish patching the DOM.
  defp filter_by_name(page, term) do
    fill(page, :filter_name, "#{term}")
    Page.wait_for_timeout!(page, @filter_debounce_ms + 50)
    wait_for_server_round_trip(page)
  end

  defp select_person(page, name) do
    row = page |> Page.locator("#people-table tbody tr", has_text: name) |> Locator.first()
    Expect.to_be_visible!(row)
    Locator.click!(row)
    wait_for_server_round_trip(page)

    detail = Page.locator(page, "#people-detail-pane")
    Expect.to_be_visible!(detail)
    detail |> Locator.locator("h3") |> Expect.to_have_text!(name)
  end

  defp create_and_assign_team(page, team_name) do
    container_sel = ~s|form[phx-change="assign_team_select"]|
    trigger = Page.locator(page, "#{container_sel} [data-select-trigger]")
    panel = Page.locator(page, "#{container_sel} [data-select-panel]")
    search = Page.locator(page, "#{container_sel} [data-select-search]")
    create = Page.locator(page, "#{container_sel} [data-select-create]")

    Expect.to_be_visible!(trigger)

    # Keep the idempotent open/fill phase together. A LiveView patch can replace
    # or close the select between either action, especially in Firefox, so each
    # retry resolves the current hook state instead of acting on a stale opening.
    Expect.to_pass!(
      fn ->
        if Locator.get_attribute!(trigger, "aria-expanded") != "true" do
          Locator.click!(trigger)
        end

        Expect.to_be_visible!(panel, timeout: 1_000)
        Expect.to_be_visible!(search, timeout: 1_000)
        Locator.fill!(search, team_name)
        Expect.to_have_value!(search, team_name)
        Expect.to_be_visible!(create, timeout: 1_000)
      end,
      timeout: 8_000
    )

    Locator.click!(create)
    wait_for_server_round_trip(page)
  end

  defp team_badge(page, team_name) do
    page
    |> Page.locator(~s|[data-testid^="person-team-badge-"]|)
    |> Locator.filter(has_text: team_name)
  end
end
