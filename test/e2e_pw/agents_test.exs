defmodule Zaq.E2EPw.AgentsTest do
  use Zaq.E2EPw.Case

  import Zaq.E2EPw.BO

  @agents_path "/bo/agents"

  # ZAQ Router is provisioned by the E2E support path and advertises deterministic
  # tool-capable models, unlike external provider catalogs.
  @tool_model "openai/gpt-oss-120b"
  @vision_model "qwen/qwen3-vl-235b-a22b-instruct"

  @mcp_endpoint_attrs %{
    type: "local",
    status: "enabled",
    timeout_ms: 5000,
    command: "echo",
    args: [],
    environments: %{},
    secret_environments: %{},
    headers: %{},
    secret_headers: %{},
    settings: %{}
  }

  # The spec's `apiRequest.newContext()`.
  defp new_request(browser) do
    APIRequest.new_context!(Playwright.request(BrowserPool.playwright(browser)))
  end

  # Clicks `click_selector` and waits for `reveal_selector` to appear, retrying the
  # click if it lands before the LiveView channel is bound (a known connection
  # race — see the same defensive pattern in `login_to_back_office`). Without this
  # the very first form-open after a fresh page load flakes intermittently.
  defp click_until_visible(page, click_selector, reveal_selector, attempts \\ 3) do
    click_until_visible(page, click_selector, reveal_selector, attempts, 0)
  end

  defp click_until_visible(page, click_selector, reveal_selector, attempts, attempt) do
    page |> Page.locator(click_selector) |> Locator.first() |> Locator.click!()

    case page |> Page.locator(reveal_selector) |> Expect.to_be_visible(timeout: 5_000) do
      :ok ->
        :ok

      {:error, error} when attempt == attempts - 1 ->
        raise error

      {:error, _error} ->
        Page.wait_for_timeout!(page, 300)
        click_until_visible(page, click_selector, reveal_selector, attempts, attempt + 1)
    end
  end

  defp open_new_agent_form(page, name) do
    goto_back_office_live(page, @agents_path)
    click_until_visible(page, ~s|[phx-click="new_agent"]|, "#configured-agent-form")
    page |> Page.locator(~s|input[name="configured_agent[name]"]|) |> Locator.fill!(name)

    page
    |> Page.locator(~s|textarea[name="configured_agent[job]"]|)
    |> Locator.fill!("Answer questions about the company.")
  end

  defp select_agent_credential(page, credential_name) do
    option =
      page
      |> Page.locator(~s|select[name="configured_agent[credential_id]"] option|)
      |> Locator.filter(has_text: credential_name)
      |> Locator.first()

    Expect.to_be_attached!(option)
    cred_value = Locator.get_attribute!(option, "value")

    page
    |> Page.locator(~s|select[name="configured_agent[credential_id]"]|)
    |> Locator.select_option!(cred_value)

    wait_for_live_view_settled(page)
  end

  defp pick_first_searchable_select_option(page, container_sel) do
    trigger = Page.locator(page, "#{container_sel} [data-select-trigger]")
    options = Page.locator(page, "#{container_sel} [data-select-option]")

    Locator.click!(trigger)
    options |> Expect.not_() |> Expect.to_have_count!(0)
    options |> Locator.first() |> Locator.click!()
  end

  defp get_zaq_router_credential(req) do
    credential = get_e2e_zaq_router_credential(req, with_api_key: true)
    assert credential["found"]
    assert credential["name"] == "ZAQ Router"
    assert credential["has_api_key"]
    credential
  end

  defp select_model_from_picker(page, model_name) do
    page
    |> Page.locator("#configured-agent-model-select")
    |> Locator.wait_for!(state: :visible, timeout: if(ci?(), do: 20_000, else: 10_000))

    # Model options can populate in stages after the credential is chosen, so
    # waiting for "any option" races an incomplete list. Wait for the *specific*
    # target model to be attached before opening the picker to click it.
    page
    |> Page.locator(~s|#configured-agent-model-select [data-select-option="#{model_name}"]|)
    |> Expect.to_have_count!(1, timeout: if(ci?(), do: 20_000, else: 10_000))

    wait_for_live_view_settled(page)
    pick_searchable_select(page, "#configured-agent-model-select", model_name)
  end

  defp modality(locator, name) do
    Locator.get_by_role(locator, :button, name: name, exact: true)
  end

  # Agents
  setup %{browser: browser} do
    req = new_request(browser)
    reset_e2e_state(req)
    APIRequestContext.dispose!(req)
    :ok
  end

  test "agents page renders list and opens create drawer", %{page: page} do
    login_to_back_office(page)
    goto_back_office_live(page, @agents_path)
    page |> Page.locator("#agents-master-pane") |> Expect.to_be_visible!()
    page |> Page.locator("#agent-form-drawer") |> Expect.to_have_count!(0)

    page |> Page.locator("#new-agent-button") |> Locator.click!()
    page |> Page.locator("#agent-form-drawer") |> Expect.to_be_visible!()
    page |> Page.locator("#configured-agent-form") |> Expect.to_be_visible!()
  end

  test "model modalities update with the credential and model in the create form", %{
    page: page,
    browser: browser
  } do
    req = new_request(browser)
    credential = get_zaq_router_credential(req)
    APIRequestContext.dispose!(req)
    login_to_back_office(page)

    custom =
      create_e2e_ai_credential(page, %{
        name: "E2E Custom Modalities",
        provider: "Custom",
        endpoint: "https://custom-endpoint.com",
        api_key: "e2e-modality-key"
      })

    agent_name = "E2E Agent Modalities"
    open_new_agent_form(page, agent_name)
    modalities = Page.locator(page, "#agent-form-modalities")
    Expect.to_have_text!(modalities, "Select a model to view modalities")
    select_agent_credential(page, credential["name"])
    select_model_from_picker(page, @vision_model)

    modalities |> modality("Input: Image") |> Expect.to_be_visible!()

    assert modalities
           |> Locator.locator("button")
           |> Locator.evaluate_all!("buttons => buttons.map(b => b.getAttribute(\"aria-label\"))") ==
             ["Input: Text", "Input: Image", "Output: Text"]

    image = modality(modalities, "Input: Image")
    tooltip = Page.locator(page, ~s|[id="#{Locator.get_attribute!(image, "aria-describedby")}"]|)
    Locator.hover!(image)
    Expect.to_be_visible!(tooltip)
    Expect.to_have_text!(tooltip, "Input: Image")
    page |> Page.mouse() |> Mouse.move!(0, 0)
    Expect.to_be_hidden!(tooltip)
    Locator.focus!(image)
    Expect.to_be_visible!(tooltip)
    page |> Page.keyboard() |> Keyboard.press!("Escape")
    Expect.to_be_hidden!(tooltip)
    page |> Page.locator("#configured-agent-form") |> Expect.to_be_visible!()

    arrow_color =
      modalities
      |> Locator.locator(".zaq-model-modalities-arrow")
      |> Locator.evaluate!("el => getComputedStyle(el).color")

    icon_color = Locator.evaluate!(image, "el => getComputedStyle(el).color")
    assert arrow_color != icon_color

    select_model_from_picker(page, @tool_model)
    modalities |> modality("Input: Text") |> Expect.to_be_visible!()
    modalities |> modality("Output: Text") |> Expect.to_be_visible!()
    select_model_from_picker(page, @vision_model)
    Expect.to_be_visible!(image)

    select_agent_credential(page, custom["name"])
    modalities |> modality("Input: Unknown") |> Expect.to_be_visible!()
    modalities |> modality("Output: Unknown") |> Expect.to_be_visible!()
    modalities |> modality("Input: Image") |> Expect.to_have_count!(0)

    select_agent_credential(page, credential["name"])
    select_model_from_picker(page, @vision_model)
    modalities |> modality("Input: Image") |> Expect.to_be_visible!()
    page |> Page.locator("#save-agent-button") |> Locator.click!()
    wait_for_live_view_settled(page)

    row = page |> Page.locator("#agents-table tr") |> Locator.filter(has_text: agent_name)
    row |> modality("Input: Image") |> Expect.to_be_visible!()
    row |> modality("Output: Text") |> Expect.to_be_visible!()
  end

  test "list modalities stay beside the model and tooltips do not select the row", %{
    page: page,
    browser: browser
  } do
    Page.set_viewport_size!(page, %{width: 1440, height: 1000})
    req = new_request(browser)
    credential = get_zaq_router_credential(req)

    agent =
      create_e2e_agent(req, %{
        name: "E2E Vision Modalities",
        job: "Answer with text.",
        model: @vision_model,
        credential_id: credential["id"]
      })

    unknown =
      create_e2e_agent(req, %{
        name: "E2E Unknown Modalities",
        job: "Unknown catalog entry.",
        model: "unlisted-custom-model",
        credential_id: credential["id"]
      })

    APIRequestContext.dispose!(req)
    login_to_back_office(page)
    goto_back_office_live(page, @agents_path)

    row = Page.locator(page, "#agent-row-#{agent["id"]}")
    modalities = Locator.locator(row, ".zaq-model-modalities")
    image = modality(modalities, "Input: Image")
    tooltip = Page.locator(page, ~s|[id="#{Locator.get_attribute!(image, "aria-describedby")}"]|)
    Locator.click!(image)
    Expect.to_be_visible!(tooltip)
    Expect.to_have_text!(tooltip, "Input: Image")
    page |> Page.locator("#agent-form-drawer") |> Expect.to_have_count!(0)
    Locator.click!(tooltip)
    page |> Page.locator("#agent-form-drawer") |> Expect.to_have_count!(0)
    Expect.to_be_visible!(tooltip)
    page |> Page.keyboard() |> Keyboard.press!("Escape")
    Expect.to_be_hidden!(tooltip)

    model_box = row |> Locator.get_by_text(@vision_model, exact: true) |> Locator.bounding_box!()
    icons_box = Locator.bounding_box!(modalities)
    assert icons_box.x >= model_box.x + model_box.width

    assert abs(icons_box.y + icons_box.height / 2 - model_box.y - model_box.height / 2) < 2

    unknown_modalities = Page.locator(page, "#agent-#{unknown["id"]}-modalities")
    unknown_modalities |> modality("Input: Unknown") |> Expect.to_be_visible!()
    unknown_modalities |> modality("Output: Unknown") |> Expect.to_be_visible!()

    row |> Locator.get_by_text(agent["name"], exact: true) |> Locator.click!()

    page
    |> Page.locator("#agent-form-modalities")
    |> modality("Input: Image")
    |> Expect.to_be_visible!()

    page |> Page.locator("#close-agent-detail") |> Locator.click!()
    page |> Page.locator(~s|input[name="filters[name]"]|) |> Locator.fill!(agent["name"])
    wait_for_live_view_settled(page)
    page |> Page.locator("#agent-row-#{unknown["id"]}") |> Expect.to_have_count!(0)
    Expect.to_be_visible!(image)
  end

  describe "modality touch tooltips and responsive layout" do
    @describetag Test.use(has_touch: true, viewport: %{width: 1440, height: 1100})

    test "equal-width desktop fields stack on mobile and icons respond to taps", %{
      page: page,
      browser: browser
    } do
      req = new_request(browser)
      credential = get_zaq_router_credential(req)

      agent =
        create_e2e_agent(req, %{
          name: "E2E Touch Modalities",
          job: "Answer with text.",
          model: @vision_model,
          credential_id: credential["id"]
        })

      APIRequestContext.dispose!(req)
      login_to_back_office(page)
      goto_back_office_live(page, @agents_path)

      row = Page.locator(page, "#agent-row-#{agent["id"]}")
      list_icon = modality(row, "Input: Image")
      Locator.tap!(list_icon)
      row |> Locator.locator(~s|[role="tooltip"]:visible|) |> Expect.to_have_text!("Input: Image")
      page |> Page.locator("#agent-form-drawer") |> Expect.to_have_count!(0)
      row |> Locator.locator(~s|[role="tooltip"]:visible|) |> Locator.tap!()
      page |> Page.locator("#agent-form-drawer") |> Expect.to_have_count!(0)
      row |> Locator.locator(~s|[role="tooltip"]:visible|) |> Expect.to_have_text!("Input: Image")

      row |> Locator.get_by_text(agent["name"], exact: true) |> Locator.click!()
      page |> Page.locator("#agent-form-modalities") |> Expect.to_be_visible!()
      credential_field = Page.locator(page, ~s|select[name="configured_agent[credential_id]"]|)
      model_field = Page.locator(page, "#configured-agent-model-select")
      modalities = Page.locator(page, "#agent-form-modalities")
      credential_box = Locator.bounding_box!(credential_field)
      model_box = Locator.bounding_box!(model_field)
      icons_box = Locator.bounding_box!(modalities)
      assert abs(credential_box.width - model_box.width) < 1
      assert abs(credential_box.y - model_box.y) < 1
      assert icons_box.x >= model_box.x + model_box.width
      assert icons_box.y + icons_box.height <= credential_box.y + credential_box.height

      Page.set_viewport_size!(page, %{width: 390, height: 844})
      mobile_credential = Locator.bounding_box!(credential_field)
      mobile_model = Locator.bounding_box!(model_field)
      mobile_icons = Locator.bounding_box!(modalities)
      assert mobile_model.y >= mobile_credential.y + mobile_credential.height
      assert mobile_icons.x >= mobile_model.x + mobile_model.width
      assert mobile_icons.y < mobile_model.y + mobile_model.height
      mobile_model_row = page |> Page.locator(".zaq-ai-model-row") |> Locator.bounding_box!()
      assert abs(mobile_credential.width - mobile_model_row.width) < 1

      modalities |> modality("Input: Image") |> Locator.tap!()
      tooltip = Locator.locator(modalities, ~s|[role="tooltip"]:visible|)
      Expect.to_have_text!(tooltip, "Input: Image")
      tooltip_box = Locator.bounding_box!(tooltip)
      assert tooltip_box.x >= 0
      assert tooltip_box.x + tooltip_box.width <= 390
      assert tooltip_box.y >= 0
      assert tooltip_box.y + tooltip_box.height <= 844

      page
      |> Page.locator("#configured-agent-form")
      |> Locator.get_by_text("Model", exact: true)
      |> Locator.tap!()

      Expect.to_be_hidden!(tooltip)
    end

    test "tooltips follow partially visible icons and hide beyond drawer and horizontal clipping",
         %{page: page, browser: browser} do
      req = new_request(browser)
      credential = get_zaq_router_credential(req)

      agent =
        create_e2e_agent(req, %{
          name: "E2E Clipped Modalities",
          job: "Answer with text.",
          model: @vision_model,
          credential_id: credential["id"]
        })

      APIRequestContext.dispose!(req)
      login_to_back_office(page)
      goto_back_office_live(page, @agents_path)

      page
      |> Page.locator("#agent-row-#{agent["id"]}")
      |> Locator.get_by_text(agent["name"], exact: true)
      |> Locator.click!()

      Page.set_viewport_size!(page, %{width: 390, height: 844})
      # Expand the real form so there is enough content below the modalities
      # to scroll the trigger past the drawer header without a layout fixture.
      page |> Page.locator("#configured-agent-form summary") |> Locator.click!()

      modalities = Page.locator(page, "#agent-form-modalities")
      image = modality(modalities, "Input: Image")

      tooltip =
        modalities
        |> Locator.get_by_role(:tooltip, include_hidden: true)
        |> Locator.filter(has_text: "Input: Image")

      body = Page.locator(page, "#agent-form-drawer .zaq-drawer-body")
      Locator.tap!(image)
      Expect.to_be_visible!(tooltip)

      # Keep half the trigger visible at the scrollport's top edge.
      Locator.evaluate!(image, """
      el => {
        const body = el.closest(".zaq-drawer-body")
        const rect = el.getBoundingClientRect()
        body.scrollTop += rect.top + rect.height / 2 - body.getBoundingClientRect().top - body.clientTop
      }
      """)

      Expect.to_be_visible!(tooltip)
      # Sample visibility and geometry together: scroll events can hide the
      # popover after to_be_visible but before a separate bounding_box call.
      Expect.poll!(
        fn ->
          Locator.evaluate!(image, """
          el => {
            const tooltip = document.getElementById(el.getAttribute("aria-describedby"))
            const body = el.closest(".zaq-drawer-body")
            if (!tooltip || !body) return Infinity

            const tip = tooltip.getBoundingClientRect()
            const scrollport = body.getBoundingClientRect()
            const trigger = el.getBoundingClientRect()
            if (!tooltip.matches(":popover-open") ||
                getComputedStyle(tooltip).visibility !== "visible" ||
                [tip, scrollport, trigger].some(rect => rect.width <= 0 || rect.height <= 0)) {
              return Infinity
            }

            const expectedTop = scrollport.y >= tip.height + 8
              ? scrollport.y - tip.height - 8
              : trigger.y + trigger.height + 8
            return Math.abs(tip.y - expectedTop)
          }
          """)
        end,
        # Infinity arrives as :infinity, which is not less than 1.
        &assert(&1 < 1)
      )

      Locator.evaluate!(body, "el => { el.scrollTop += 40 }")
      Expect.to_be_hidden!(tooltip)
      Locator.tap!(image)
      Expect.to_be_visible!(tooltip)

      # A narrow overflow fixture exercises the same horizontal scrollport used
      # by the form when the catalog contains more modalities than fit.
      container = Page.locator(page, ".zaq-ai-model-modalities")
      text = modality(modalities, "Input: Text")

      text_tooltip =
        modalities
        |> Locator.get_by_role(:tooltip, include_hidden: true)
        |> Locator.filter(has_text: "Input: Text")

      Locator.evaluate!(container, ~s|el => { el.style.width = "16px" }|)
      Locator.tap!(text)
      Expect.to_be_visible!(text_tooltip)
      Locator.evaluate!(container, "el => { el.scrollLeft = el.scrollWidth }")
      Expect.to_be_hidden!(text_tooltip)

      Locator.evaluate!(
        container,
        ~s|el => { el.style.removeProperty("width"); el.scrollLeft = 0 }|
      )

      Locator.tap!(image)
      Expect.to_be_visible!(tooltip)
      page |> Page.keyboard() |> Keyboard.press!("Escape")
      Expect.to_be_hidden!(tooltip)
    end
  end

  # ─── Existing tests (with model-picker fix applied) ───────────────────────

  test "create an agent with AI credentials", %{page: page, browser: browser} do
    req = new_request(browser)
    credential = get_zaq_router_credential(req)
    APIRequestContext.dispose!(req)
    login_to_back_office(page)

    agent_name = "E2E Agent #{System.system_time(:millisecond)}"
    open_new_agent_form(page, agent_name)
    select_agent_credential(page, credential["name"])
    select_model_from_picker(page, @tool_model)

    page |> Page.locator("#save-agent-button") |> Locator.click!()
    wait_for_live_view_settled(page)

    page |> Page.get_by_text(agent_name) |> Expect.to_be_visible!()
  end

  test "model selection populates context window and preserves manual overrides", %{page: page} do
    login_to_back_office(page)

    credential =
      create_e2e_ai_credential(page, %{
        name: "E2E OpenAI Context #{System.system_time(:millisecond)}",
        provider: "OpenAI",
        endpoint: "https://api.openai.com/v1",
        api_key: "e2e-key-#{System.system_time(:millisecond)}",
        description: "Agents spec context-window credential"
      })

    open_new_agent_form(page, "E2E Agent Context Window #{System.system_time(:millisecond)}")
    select_agent_credential(page, credential["name"])
    select_model_from_picker(page, "gpt-4.1-mini")

    context_window =
      Page.locator(page, ~s|input[name="configured_agent[model_max_context_tokens]"]|)

    Expect.to_have_value!(context_window, ~r/[1-9][0-9]+/)
    model_default = Locator.input_value!(context_window)

    page |> Page.locator("#agent-advanced-options summary") |> Locator.click!()
    Locator.fill!(context_window, "120000")

    page
    |> Page.locator(~s|input[name="configured_agent[name]"]|)
    |> Locator.fill!("E2E Agent Context Override #{System.system_time(:millisecond)}")

    wait_for_live_view_settled(page)

    Expect.to_have_value!(context_window, "120000")

    page |> Page.locator("#reset-model-context-tokens") |> Locator.click!()
    wait_for_live_view_settled(page)

    Expect.to_have_value!(context_window, model_default)
  end

  test "add tools and MCP endpoint for a tool-capable model", %{page: page, browser: browser} do
    req = new_request(browser)
    credential = get_zaq_router_credential(req)
    mcp_name = "E2E MCP #{System.system_time(:millisecond)}-#{:rand.uniform(10_000) - 1}"
    mcp = create_e2e_mcp_endpoint(req, Map.put(@mcp_endpoint_attrs, :name, mcp_name))
    APIRequestContext.dispose!(req)
    login_to_back_office(page)

    open_new_agent_form(page, "E2E Agent Tools MCP #{System.system_time(:millisecond)}")
    select_agent_credential(page, credential["name"])
    select_model_from_picker(page, @tool_model)
    wait_for_live_view_settled(page)

    page |> Page.locator("#add-tools-button") |> Expect.to_be_enabled!()
    page |> Page.locator("#add-mcp-button") |> Expect.to_be_enabled!()

    page |> Page.locator("#add-tools-button") |> Locator.click!()
    page |> Page.locator("#agent-tools-picker-modal") |> Expect.to_be_visible!()
    pick_first_searchable_select_option(page, "#agent-tools-picker-select")
    wait_for_live_view_settled(page)
    page |> Page.locator("[data-selected-tool-key]") |> Expect.not_() |> Expect.to_have_count!(0)

    page
    |> Page.locator("#agent-tools-picker-modal")
    |> Locator.get_by_role(:button)
    |> Locator.first()
    |> Locator.click!()

    page |> Page.locator("#agent-tools-picker-modal") |> Expect.not_() |> Expect.to_be_visible!()
    wait_for_live_view_settled(page)

    page |> Page.locator("#add-mcp-button") |> Locator.click!()
    page |> Page.locator("#agent-mcp-picker-modal") |> Expect.to_be_visible!()
    pick_searchable_select(page, "#agent-mcp-picker-select", "#{mcp["name"]} (##{mcp["id"]})")
    wait_for_live_view_settled(page)

    page
    |> Page.locator("#agent-mcp-picker-modal")
    |> Locator.get_by_role(:button)
    |> Locator.first()
    |> Locator.click!()

    page |> Page.locator("#agent-mcp-picker-modal") |> Expect.not_() |> Expect.to_be_visible!()

    page
    |> Page.locator(~s|[data-selected-mcp-endpoint-id="#{mcp["id"]}"]|)
    |> Expect.to_be_visible!()
  end

  test "custom model shows unknown-capability notice and keeps MCP/tools actions enabled", %{
    page: page
  } do
    login_to_back_office(page)

    credential =
      create_e2e_ai_credential(page, %{
        name: "E2E Custom #{System.system_time(:millisecond)}",
        provider: "Custom",
        endpoint: "https://custom-endpoint.com",
        api_key: "e2e-key-#{System.system_time(:millisecond)}",
        description: "Agents spec seeded credential"
      })

    open_new_agent_form(page, "E2E Agent Custom #{System.system_time(:millisecond)}")
    select_agent_credential(page, credential["name"])

    page |> Page.locator("#configured-agent-model-select") |> Expect.to_have_count!(0)
    model_input = Page.locator(page, ~s|input[type="text"][name="configured_agent[model]"]|)
    Expect.to_be_visible!(model_input)
    Locator.fill!(model_input, "unlisted-custom-model")
    Locator.press!(model_input, "Tab")
    wait_for_live_view_settled(page)

    page
    |> Page.get_by_text(
      "Tool-calling support could not be determined for this model. Only add tools or MCP endpoints if the model supports tool calling; otherwise, requests may fail at runtime."
    )
    |> Expect.to_be_visible!()

    page
    |> Page.get_by_text(
      "Selected model does not support tool calling. MCP endpoints and tools are unavailable for this model."
    )
    |> Expect.to_have_count!(0)

    page |> Page.locator("#add-mcp-button") |> Expect.to_be_enabled!()
    page |> Page.locator("#add-tools-button") |> Expect.to_be_enabled!()
  end

  test "confirmed unsupported model disables MCP/tools actions", %{page: page} do
    login_to_back_office(page)

    credential =
      create_e2e_ai_credential(page, %{
        name: "E2E Unsupported #{System.system_time(:millisecond)}",
        provider: "OpenAI",
        endpoint: "https://api.openai.com/v1",
        api_key: "e2e-key-#{System.system_time(:millisecond)}",
        description: "Agents spec seeded credential"
      })

    open_new_agent_form(page, "E2E Agent Unsupported #{System.system_time(:millisecond)}")
    select_agent_credential(page, credential["name"])
    select_model_from_picker(page, "gpt-5.1-2025-11-13")
    wait_for_live_view_settled(page)

    page
    |> Page.get_by_text(
      "Selected model does not support tool calling. MCP endpoints and tools are unavailable for this model."
    )
    |> Expect.to_be_visible!()

    page |> Page.locator("#add-mcp-button") |> Expect.to_be_disabled!()
    page |> Page.locator("#add-tools-button") |> Expect.to_be_disabled!()
  end

  # ─── Phase 1: CRUD ────────────────────────────────────────────────────────

  test "cancel agent form discards changes", %{page: page, browser: browser} do
    req = new_request(browser)
    get_zaq_router_credential(req)
    APIRequestContext.dispose!(req)
    login_to_back_office(page)

    goto_back_office_live(page, @agents_path)
    click_until_visible(page, ~s|[phx-click="new_agent"]|, "#configured-agent-form")

    page
    |> Page.locator(~s|input[name="configured_agent[name]"]|)
    |> Locator.fill!("Should Not Be Saved")

    page |> Page.locator("#close-agent-detail") |> Locator.click!()
    wait_for_live_view_settled(page)

    page |> Page.locator("#configured-agent-form") |> Expect.not_() |> Expect.to_be_visible!()
    page |> Page.get_by_text("Should Not Be Saved") |> Expect.not_() |> Expect.to_be_visible!()
  end

  test "edit an existing agent and save updates", %{page: page, browser: browser} do
    req = new_request(browser)
    credential = get_zaq_router_credential(req)

    agent =
      create_e2e_agent(req, %{
        name: "E2E Agent To Edit",
        job: "Original job description.",
        model: @tool_model,
        credential_id: credential["id"]
      })

    APIRequestContext.dispose!(req)
    login_to_back_office(page)

    goto_back_office_live(page, @agents_path)

    click_until_visible(
      page,
      "#agent-row-#{agent["id"]} td:first-child",
      "#configured-agent-form"
    )

    wait_for_live_view_settled(page)

    updated_name = "E2E Agent Edited #{System.system_time(:millisecond)}"
    page |> Page.locator(~s|input[name="configured_agent[name]"]|) |> Locator.fill!(updated_name)
    page |> Page.locator("#save-agent-button") |> Locator.click!()
    wait_for_live_view_settled(page)

    page |> Page.get_by_text("Agent updated") |> Expect.to_be_visible!()
    page |> Page.get_by_text(updated_name) |> Expect.to_be_visible!()
  end

  test "delete an agent removes it from the list", %{page: page, browser: browser} do
    req = new_request(browser)
    credential = get_zaq_router_credential(req)

    agent =
      create_e2e_agent(req, %{
        name: "E2E Agent To Delete",
        job: "Will be deleted.",
        model: @tool_model,
        credential_id: credential["id"]
      })

    APIRequestContext.dispose!(req)
    login_to_back_office(page)

    goto_back_office_live(page, @agents_path)
    page |> Page.get_by_text(agent["name"]) |> Expect.to_be_visible!()

    # Selecting the row opens the detail form (where Delete lives); retry the
    # click until the delete button appears so a patch-race select doesn't leave
    # us clicking a button that isn't rendered yet.
    click_until_visible(
      page,
      "#agent-row-#{agent["id"]} td:first-child",
      ~s|[phx-click="delete_agent"][phx-value-id="#{agent["id"]}"]|
    )

    page
    |> Page.locator(~s|[phx-click="delete_agent"][phx-value-id="#{agent["id"]}"]|)
    |> Locator.click!()

    wait_for_live_view_settled(page)

    page |> Page.get_by_text(agent["name"]) |> Expect.not_() |> Expect.to_be_visible!()
  end

  test "filter agents by name shows only matching agents", %{page: page, browser: browser} do
    req = new_request(browser)
    credential = get_zaq_router_credential(req)

    agent_a =
      create_e2e_agent(req, %{
        name: "E2E FilterAlpha",
        job: "First agent.",
        model: @tool_model,
        credential_id: credential["id"]
      })

    agent_b =
      create_e2e_agent(req, %{
        name: "E2E FilterBeta",
        job: "Second agent.",
        model: @tool_model,
        credential_id: credential["id"]
      })

    APIRequestContext.dispose!(req)
    login_to_back_office(page)

    goto_back_office_live(page, @agents_path)
    page |> Page.get_by_text(agent_a["name"]) |> Expect.to_be_visible!()
    page |> Page.get_by_text(agent_b["name"]) |> Expect.to_be_visible!()

    # Re-apply the filter until it takes: a bare `fill!` can fire its
    # phx-change while LiveView is mid-patch, dropping the event and leaving the
    # list unfiltered. Retrying the whole clear+fill+assert absorbs that race.
    name_filter = Page.locator(page, ~s|input[name="filters[name]"]|)

    Expect.to_pass!(
      fn ->
        Locator.fill!(name_filter, "")
        Locator.fill!(name_filter, "FilterAlpha")
        page |> Page.get_by_text(agent_b["name"]) |> Expect.to_have_count!(0, timeout: 2_000)
      end,
      timeout: 15_000
    )

    page |> Page.get_by_text(agent_a["name"]) |> Expect.to_be_visible!()
  end

  # ─── Phase 2: Tools & MCP (remove / empty picker) ────────────────────────

  test "remove a tool from the agent form", %{page: page, browser: browser} do
    req = new_request(browser)
    credential = get_zaq_router_credential(req)
    APIRequestContext.dispose!(req)
    login_to_back_office(page)

    open_new_agent_form(page, "E2E Agent Remove Tool #{System.system_time(:millisecond)}")
    select_agent_credential(page, credential["name"])
    select_model_from_picker(page, @tool_model)
    wait_for_live_view_settled(page)

    page |> Page.locator("#add-tools-button") |> Locator.click!()
    page |> Page.locator("#agent-tools-picker-modal") |> Expect.to_be_visible!()
    pick_first_searchable_select_option(page, "#agent-tools-picker-select")
    wait_for_live_view_settled(page)
    tool_badge = page |> Page.locator("[data-selected-tool-key]") |> Locator.first()
    Expect.to_be_visible!(tool_badge)
    tool_key = Locator.get_attribute!(tool_badge, "data-selected-tool-key")

    page
    |> Page.locator("#agent-tools-picker-modal")
    |> Locator.get_by_role(:button)
    |> Locator.first()
    |> Locator.click!()

    page |> Page.locator("#agent-tools-picker-modal") |> Expect.not_() |> Expect.to_be_visible!()

    page
    |> Page.locator(~s|[phx-click="remove_tool"][phx-value-key="#{tool_key}"]|)
    |> Locator.click!()

    wait_for_live_view_settled(page)

    page |> Page.locator("[data-selected-tool-key]") |> Expect.to_have_count!(0)
  end

  test "remove an MCP endpoint from the agent form", %{page: page, browser: browser} do
    req = new_request(browser)
    credential = get_zaq_router_credential(req)

    mcp =
      create_e2e_mcp_endpoint(
        req,
        Map.put(@mcp_endpoint_attrs, :name, "E2E MCP Remove #{System.system_time(:millisecond)}")
      )

    APIRequestContext.dispose!(req)
    login_to_back_office(page)

    open_new_agent_form(page, "E2E Agent Remove MCP #{System.system_time(:millisecond)}")
    select_agent_credential(page, credential["name"])
    select_model_from_picker(page, @tool_model)
    wait_for_live_view_settled(page)

    # Add MCP
    page |> Page.locator("#add-mcp-button") |> Locator.click!()
    page |> Page.locator("#agent-mcp-picker-modal") |> Expect.to_be_visible!()
    pick_searchable_select(page, "#agent-mcp-picker-select", "#{mcp["name"]} (##{mcp["id"]})")

    page
    |> Page.locator("#agent-mcp-picker-modal")
    |> Locator.get_by_role(:button)
    |> Locator.first()
    |> Locator.click!()

    page |> Page.locator("#agent-mcp-picker-modal") |> Expect.not_() |> Expect.to_be_visible!()

    page
    |> Page.locator(~s|[data-selected-mcp-endpoint-id="#{mcp["id"]}"]|)
    |> Expect.to_be_visible!()

    # Remove MCP
    page
    |> Page.locator(~s|[phx-click="remove_mcp"][phx-value-id="#{mcp["id"]}"]|)
    |> Locator.click!()

    wait_for_live_view_settled(page)

    page
    |> Page.locator(~s|[data-selected-mcp-endpoint-id="#{mcp["id"]}"]|)
    |> Expect.not_()
    |> Expect.to_be_visible!()
  end

  # ─── Phase 3: Error handling & validation ─────────────────────────────────

  test "save fails with inline error when name is blank", %{page: page, browser: browser} do
    req = new_request(browser)
    credential = get_zaq_router_credential(req)
    APIRequestContext.dispose!(req)
    login_to_back_office(page)

    goto_back_office_live(page, @agents_path)
    click_until_visible(page, ~s|[phx-click="new_agent"]|, "#configured-agent-form")
    select_agent_credential(page, credential["name"])

    # Leave name blank and submit
    page |> Page.locator("#save-agent-button") |> Locator.click!()
    wait_for_live_view_settled(page)

    page |> Page.locator("#configured-agent-form") |> Expect.to_be_visible!()
    page |> Page.get_by_text(~r/can't be blank/i) |> Locator.first() |> Expect.to_be_visible!()
  end

  test "save fails with inline error when no credential selected", %{page: page} do
    login_to_back_office(page)

    goto_back_office_live(page, @agents_path)
    click_until_visible(page, ~s|[phx-click="new_agent"]|, "#configured-agent-form")

    page
    |> Page.locator(~s|input[name="configured_agent[name]"]|)
    |> Locator.fill!("No Credential Agent")

    page |> Page.locator("#save-agent-button") |> Locator.click!()
    wait_for_live_view_settled(page)

    page |> Page.locator("#configured-agent-form") |> Expect.to_be_visible!()
    page |> Page.get_by_text(~r/can't be blank/i) |> Locator.first() |> Expect.to_be_visible!()
  end

  test "invalid JSON in advanced options shows inline error", %{page: page, browser: browser} do
    req = new_request(browser)
    credential = get_zaq_router_credential(req)
    APIRequestContext.dispose!(req)
    login_to_back_office(page)

    open_new_agent_form(page, "E2E Agent JSON Error #{System.system_time(:millisecond)}")
    select_agent_credential(page, credential["name"])
    select_model_from_picker(page, @tool_model)
    wait_for_live_view_settled(page)

    page |> Page.locator("#agent-advanced-options summary") |> Locator.click!()

    page
    |> Page.locator(~s|textarea[name="configured_agent[advanced_options_json]"]|)
    |> Locator.fill!("{invalid json}")

    page |> Page.locator("#save-agent-button") |> Locator.click!()
    wait_for_live_view_settled(page)

    page |> Page.locator("#configured-agent-form") |> Expect.to_be_visible!()
    page |> Page.get_by_text(~r/valid JSON/i) |> Locator.first() |> Expect.to_be_visible!()
  end

  test "non-object JSON in advanced options shows inline error", %{page: page, browser: browser} do
    req = new_request(browser)
    credential = get_zaq_router_credential(req)
    APIRequestContext.dispose!(req)
    login_to_back_office(page)

    open_new_agent_form(page, "E2E Agent JSON Object Error #{System.system_time(:millisecond)}")
    select_agent_credential(page, credential["name"])
    select_model_from_picker(page, @tool_model)
    wait_for_live_view_settled(page)

    page |> Page.locator("#agent-advanced-options summary") |> Locator.click!()

    page
    |> Page.locator(~s|textarea[name="configured_agent[advanced_options_json]"]|)
    |> Locator.fill!(~s|"just a string"|)

    page |> Page.locator("#save-agent-button") |> Locator.click!()
    wait_for_live_view_settled(page)

    page |> Page.locator("#configured-agent-form") |> Expect.to_be_visible!()

    page
    |> Page.get_by_text(~r/must be a JSON object/i)
    |> Locator.first()
    |> Expect.to_be_visible!()
  end
end
