defmodule Zaq.E2EPw.SystemConfigTest.Shared do
  @moduledoc """
  The spec's "System Config" describe: its helpers, and its hooks for the modules of its nested
  describes (`use Zaq.E2EPw.SystemConfigTest.Shared`).

  The nested describes with hooks of their own are one module each. Each module resets in
  `setup_all` and seeds its own credential, where the spec reset and seeded once for the file:
  other files' modules run between these ones and reset the database.
  """

  alias Playwright.{APIRequest, APIRequestContext, Expect, Locator, Page, Promise}
  alias Playwright.Test.BrowserPool
  import Zaq.E2EPw.BO

  defmacro __using__(_opts) do
    quote do
      use Zaq.E2EPw.Case

      import Zaq.E2EPw.BO
      import Zaq.E2EPw.SystemConfigTest.Shared

      setup_all %{browser: browser}, do: before_all(browser)
      setup %{page: page, seeded_store: store}, do: before_each(page, store)
    end
  end

  def config_path, do: "/bo/system-config"
  def e2e_endpoint, do: "http://localhost:11434/v1"

  # Selectors using phx-click/phx-value attributes: never rely on text position.
  def sel(:tab_telemetry), do: ~s|[phx-value-tab="telemetry"]|
  def sel(:tab_embedding), do: ~s|[phx-value-tab="rag"]|
  def sel(:tab_image_to_text), do: ~s|[phx-value-tab="rag"]|
  def sel(:tab_ai_credentials), do: ~s|[phx-value-tab="ai_credentials"]|
  def sel(:tab_auth_credentials), do: ~s|[phx-value-tab="auth_credentials"]|
  def sel(:tab_global), do: ~s|[phx-value-tab="global"]|
  def sel(:tab_people_access), do: ~s|[phx-value-tab="people_access"]|
  def sel(:embedding_form), do: "#embedding-config-form"
  def sel(:image_to_text_form), do: "#image-to-text-config-form"
  def sel(:telemetry_form), do: "#telemetry-config-form"
  def sel(:ai_credential_form), do: "#ai-credential-form"
  def sel(:unlock_trigger), do: ~s|[phx-click="unlock_embedding"]|
  def sel(:cancel_unlock), do: ~s|button[phx-click="cancel_unlock_embedding"]:not([aria-label])|
  def sel(:confirm_unlock), do: ~s|[phx-click="confirm_unlock_embedding"]|
  def sel(:cancel_save), do: ~s|button[phx-click="cancel_save_embedding"]|
  def sel(:confirm_save), do: ~s|[phx-click="confirm_save_embedding"]|

  # `let seededCredential` of the spec: created by the first test of the module that runs.
  def before_all(browser) do
    req = APIRequest.new_context!(Playwright.request(BrowserPool.playwright(browser)))
    reset_e2e_state(req)
    APIRequestContext.dispose!(req)
    {:ok, seeded_store} = Agent.start(fn -> nil end)
    ExUnit.Callbacks.on_exit(fn -> Agent.stop(seeded_store) end)
    %{seeded_store: seeded_store}
  end

  def before_each(page, store) do
    login_to_back_office(page, return_to: config_path())

    seeded_credential =
      case Agent.get(store, & &1) do
        nil ->
          credential =
            create_e2e_ai_credential(page, %{
              name: "E2E System Config #{System.system_time(:millisecond)}",
              provider: "Custom",
              endpoint: e2e_endpoint(),
              api_key: "e2e-key-#{System.system_time(:millisecond)}",
              description: "System Config prerequisite"
            })

          Agent.update(store, fn _ -> credential end)
          goto_back_office_live(page, config_path())
          credential

        credential ->
          credential
      end

    %{seeded_credential: seeded_credential}
  end

  # At least one of the two locators becomes visible. Use in place of
  # `Locator.is_visible!(a) or Locator.is_visible!(b)`, which is a point-in-time check and
  # returns false if neither has had time to render yet.
  def expect_either_visible(a, b, opts \\ []) do
    timeout = opts[:timeout] || 10_000

    [a, b]
    |> Enum.map(fn locator ->
      Promise.async(fn ->
        locator |> Locator.first() |> Locator.wait_for!(state: :visible, timeout: timeout)
      end)
    end)
    |> Promise.race()
    |> Promise.await!()
  end

  def switch_system_config_tab(page, tab_selector, url_pattern, target_locator) do
    Expect.to_pass!(
      fn ->
        page |> Page.locator(tab_selector) |> Locator.click!()
        Expect.to_have_url!(page, url_pattern, timeout: 2_000)
        Expect.to_be_visible!(target_locator, timeout: 2_000)
      end,
      timeout: expect_timeout()
    )
  end

  def open_retrieval_settings(page) do
    goto_back_office_live(page, "#{config_path()}?tab=rag")
    advanced = Page.locator(page, "#rag-retrieval-advanced")

    unless Locator.evaluate!(advanced, "element => element.open") do
      advanced |> Locator.locator("summary") |> Locator.click!()
    end
  end

  # Read the numeric value of an input and return an integer guaranteed != current.
  def different_dimension(page) do
    raw =
      page
      |> Page.locator(~s|input[name="embedding_config[dimension]"]|)
      |> Locator.input_value!()

    current =
      case Integer.parse(raw) do
        {value, _} when value != 0 -> value
        _ -> 3584
      end

    # Use an alternating pair so re-runs always differ from the DB.
    if current == 512, do: 768, else: 512
  end
end

defmodule Zaq.E2EPw.SystemConfigTest do
  use Zaq.E2EPw.SystemConfigTest.Shared

  # System Config

  describe "tab navigation" do
    test "default tab is AI Credentials", %{page: page} do
      page |> Page.get_by_role(:heading, name: "AI Credentials") |> Expect.to_be_visible!()
      page |> Page.locator("#llm-config-form") |> Expect.to_have_count!(0)
      page |> Page.locator(sel(:embedding_form)) |> Expect.not_() |> Expect.to_be_visible!()
      page |> Page.locator(sel(:image_to_text_form)) |> Expect.not_() |> Expect.to_be_visible!()
    end

    test "global LLM controls are no longer exposed", %{page: page} do
      page |> Page.locator(~s|[phx-value-tab="llm"]|) |> Expect.to_have_count!(0)
      page |> Page.locator("#llm-config-form") |> Expect.to_have_count!(0)
    end

    test "switching to Embedding shows only embedding form and updates URL", %{page: page} do
      switch_system_config_tab(
        page,
        sel(:tab_embedding),
        ~r/tab=rag/,
        Page.locator(page, sel(:embedding_form))
      )
    end

    test "switching to Image to Text shows only that form and updates URL", %{page: page} do
      switch_system_config_tab(
        page,
        sel(:tab_image_to_text),
        ~r/tab=rag/,
        Page.locator(page, sel(:image_to_text_form))
      )
    end

    test "switching to Auth Credentials shows auth credentials panel and updates URL", %{
      page: page
    } do
      switch_system_config_tab(
        page,
        sel(:tab_auth_credentials),
        ~r/tab=auth_credentials/,
        Page.get_by_role(page, :heading, name: "Auth Credentials")
      )
    end

    test "switching to AI Credentials shows credentials panel and updates URL", %{page: page} do
      switch_system_config_tab(
        page,
        sel(:tab_ai_credentials),
        ~r/tab=ai_credentials/,
        Page.get_by_role(page, :heading, name: "AI Credentials")
      )
    end

    test "direct URL ?tab=llm redirects to RAG", %{page: page} do
      goto_back_office_live(page, "#{config_path()}?tab=llm")
      Expect.to_have_url!(page, ~r/tab=rag/)
      page |> Page.locator("#rag-config") |> Expect.to_be_visible!()
      page |> Page.locator("#llm-config-form") |> Expect.to_have_count!(0)
    end

    test "direct URL ?tab=embedding loads Embedding tab", %{page: page} do
      goto_back_office_live(page, "#{config_path()}?tab=embedding")
      page |> Page.locator(sel(:embedding_form)) |> Expect.to_be_visible!()
    end

    test "direct URL ?tab=image_to_text loads Image to Text tab", %{page: page} do
      goto_back_office_live(page, "#{config_path()}?tab=image_to_text")
      page |> Page.locator(sel(:image_to_text_form)) |> Expect.to_be_visible!()
    end

    test "direct URL ?tab=ai_credentials loads AI Credentials tab", %{page: page} do
      goto_back_office_live(page, "#{config_path()}?tab=ai_credentials")
      page |> Page.get_by_role(:heading, name: "AI Credentials") |> Expect.to_be_visible!()
    end

    test "unknown ?tab value falls back to AI Credentials", %{page: page} do
      goto_back_office_live(page, "#{config_path()}?tab=nonexistent")
      page |> Page.get_by_role(:heading, name: "AI Credentials") |> Expect.to_be_visible!()
    end
  end

  describe "RAG configuration" do
    test "specialized models filter by purpose, persist independently, reset and clear", %{
      page: page,
      seeded_credential: seeded_credential
    } do
      credential =
        create_e2e_ai_credential(page, %{
          name: "RAG catalog #{System.system_time(:millisecond)}",
          provider: "openrouter",
          endpoint: "http://127.0.0.1:4002/e2e/llm",
          auth_kind: "none"
        })

      goto_back_office_live(page, "#{config_path()}?tab=rag")

      selections = [
        %{
          kind: "reranking",
          title: "Re-ranking",
          model: "cohere/rerank-v3.5",
          label: "Cohere: Rerank v3.5",
          excluded: "liquid/d1"
        }
      ]

      for selection <- selections do
        prefix = "#rag-#{selection.kind}"

        page
        |> Page.locator("#{prefix}-section")
        |> Expect.to_contain_text!("Not active in the RAG pipeline.")

        page |> Page.locator("#{prefix}-section") |> Locator.scroll_into_view_if_needed!()
        pick_searchable_select(page, "#{prefix}-credential-select", credential["name"])
        wait_for_live_view_settled(page)

        page
        |> Page.locator(~s|#{prefix}-model-select li[data-select-value="#{selection.model}"]|)
        |> Expect.to_have_count!(1)

        page
        |> Page.locator(~s|#{prefix}-model-select li[data-select-value="#{selection.excluded}"]|)
        |> Expect.to_have_count!(0)

        page
        |> Page.locator(~s|#{prefix}-model-select li[data-select-value="openai/gpt-4o"]|)
        |> Expect.to_have_count!(0)

        pick_searchable_select(page, "#{prefix}-model-select", selection.label)

        page
        |> Page.locator("#{prefix}-form")
        |> Locator.get_by_role(:button, name: "Save #{selection.title} Settings")
        |> Locator.click!()

        page
        |> Page.get_by_text("RAG model settings saved. Not active in the pipeline.")
        |> Expect.to_be_visible!()
      end

      goto_back_office_live(page, "#{config_path()}?tab=rag")
      page |> Page.locator("#rag-decision-section") |> Expect.to_have_count!(0)

      for selection <- selections do
        page
        |> Page.locator("#rag-#{selection.kind}-credential-select input[data-select-value]")
        |> Expect.to_have_value!(to_string(credential["id"]))

        page
        |> Page.locator("#rag-#{selection.kind}-model-select input[data-select-value]")
        |> Expect.to_have_value!(selection.model)
      end

      # A forged selection must be rejected by the server, not merely hidden by the dropdown.
      page
      |> Page.locator("#rag-reranking-model-select input[data-select-value]")
      |> Locator.evaluate!(~s|input => { input.value = "liquid/d1" }|)

      page
      |> Page.locator("#rag-reranking-form")
      |> Locator.get_by_role(:button, name: "Save Re-ranking Settings")
      |> Locator.click!()

      page
      |> Page.locator("#rag-reranking-section .zaq-field-error")
      |> Expect.to_contain_text!("is not a compatible model")

      goto_back_office_live(page, "#{config_path()}?tab=rag")

      page
      |> Page.locator("#rag-reranking-model-select input[data-select-value]")
      |> Expect.to_have_value!("cohere/rerank-v3.5")

      page |> Page.locator("#rag-reranking-section") |> Locator.scroll_into_view_if_needed!()
      pick_searchable_select(page, "#rag-reranking-credential-select", seeded_credential["name"])

      page
      |> Page.locator(~s|#rag-reranking-form input[type="text"][name="rag_model_config[model]"]|)
      |> Expect.to_have_value!("")

      page
      |> Page.locator("#rag-reranking-section")
      |> Expect.not_()
      |> Expect.to_contain_text!("No compatible models.")

      page |> Page.locator("#rag-reranking-model-select") |> Expect.to_have_count!(0)
      pick_searchable_select(page, "#rag-reranking-credential-select", "Not configured")

      page
      |> Page.locator("#rag-reranking-form")
      |> Locator.get_by_role(:button, name: "Save Re-ranking Settings")
      |> Locator.click!()

      page
      |> Page.get_by_text("RAG model settings saved. Not active in the pipeline.")
      |> Expect.to_be_visible!()

      goto_back_office_live(page, "#{config_path()}?tab=rag")

      page
      |> Page.locator("#rag-reranking-model-select input[data-select-value]")
      |> Expect.to_have_value!("")

      page
      |> Page.locator("#rag-reranking-credential-select input[data-select-value]")
      |> Expect.to_have_value!("")

      page |> Page.locator("#rag-decision-section") |> Expect.to_have_count!(0)
    end

    test "advanced retrieval saves complementary weights without unlocking embeddings", %{
      page: page
    } do
      goto_back_office_live(page, "#{config_path()}?tab=rag")
      advanced = Page.locator(page, "#retrieval-section #rag-retrieval-advanced")
      advanced |> Expect.not_() |> Expect.to_have_attribute!("open", "")
      advanced |> Locator.locator("summary") |> Locator.focus!()
      page |> Page.keyboard() |> Keyboard.press!("Enter")
      page |> Page.locator("#retrieval-config-form") |> Expect.to_be_visible!()
      dimension = Page.locator(page, ~s|input[name="embedding_config[dimension]"]|)
      saved_dimension = Locator.input_value!(dimension)
      Expect.to_be_disabled!(dimension)

      page
      |> Page.locator(~s|input[name="retrieval_config[max_cosine_distance]"]|)
      |> Locator.fill!("0.6")

      page
      |> Page.locator(~s|input[name="retrieval_config[fusion_bm25_weight]"]|)
      |> Locator.fill!("0.35")

      page
      |> Page.locator(~s|input[name="retrieval_config[fusion_vector_weight]"]|)
      |> Expect.to_have_value!("0.65")

      page |> Page.get_by_role(:button, name: "Save Retrieval Settings") |> Locator.click!()
      page |> Page.get_by_text("Retrieval settings saved.") |> Expect.to_be_visible!()
      page |> Page.locator("#embedding-save-confirm-modal") |> Expect.to_have_count!(0)
      Expect.to_be_disabled!(dimension)
      Expect.to_have_value!(dimension, saved_dimension)
      open_retrieval_settings(page)

      page
      |> Page.locator(~s|input[name="retrieval_config[max_cosine_distance]"]|)
      |> Expect.to_have_value!("0.6")

      page
      |> Page.locator(~s|input[name="retrieval_config[fusion_bm25_weight]"]|)
      |> Expect.to_have_value!("0.35")

      page
      |> Page.locator(~s|input[name="retrieval_config[fusion_vector_weight]"]|)
      |> Expect.to_have_value!("0.65")

      Expect.to_have_value!(dimension, saved_dimension)
      Expect.to_be_disabled!(dimension)
    end

    for theme <- ["light", "dark"] do
      @theme theme

      test "#{theme} theme keeps RAG controls readable at desktop and mobile widths", %{
        page: page
      } do
        theme = @theme
        goto_back_office_live(page, "#{config_path()}?tab=rag")

        page
        |> Page.get_by_role(:button, name: "Use #{theme} theme", exact: true)
        |> Locator.click!()

        page |> Page.locator("html") |> Expect.to_have_attribute!("data-theme", theme)

        for width <- [1280, 390] do
          Page.set_viewport_size!(page, %{width: width, height: 900})

          if width == 390 do
            collapse_sidebar(page)
            page |> Page.locator("#bo-main") |> Expect.to_have_css!("margin-left", "60px")
          end

          for section <- ["embedding", "image-to-text", "rag-reranking"] do
            page |> Page.locator("##{section}-section h2") |> Expect.to_be_visible!()
          end

          layout =
            page
            |> Page.locator("#rag-config")
            |> Locator.evaluate!("""
            root => {
              const embedding = root.querySelector("#embedding-section")
              const input = root.querySelector('input[name="embedding_config[chunk_min_tokens]"]')
              const style = getComputedStyle(input)
              return {
                overflow: document.documentElement.scrollWidth > innerWidth,
                width: embedding.getBoundingClientRect().width,
                text: style.color,
                background: style.backgroundColor,
                cards: ["reranking"].map(kind => {
                  const rect = root.querySelector(`#rag-${kind}-section`).getBoundingClientRect()
                  return { x: rect.x, y: rect.y, right: rect.right }
                }),
                offscreen: [...root.querySelectorAll("input,button")].filter(element => element.getBoundingClientRect().right > innerWidth + 1).length,
              }
            }
            """)

          assert layout["overflow"] == false
          assert layout["offscreen"] == 0
          assert layout["width"] > 240
          assert layout["text"] != layout["background"]

          assert layout["text"] ==
                   if(theme == "dark", do: "rgb(243, 245, 247)", else: "rgb(12, 19, 36)")

          assert length(layout["cards"]) == 1
          assert Enum.at(layout["cards"], 0)["right"] <= width

          page
          |> Page.locator("#rag-config")
          |> Locator.screenshot!(path: Test.output_path("rag-#{theme}-#{width}.png"))

          goto_back_office_live(page, "#{config_path()}?tab=global")
          page |> Page.locator("#decision-model-section") |> Expect.to_be_visible!()

          global_layout =
            page
            |> Page.locator("#global-model-row")
            |> Locator.evaluate!("""
            row => ({
              overflow: document.documentElement.scrollWidth > innerWidth,
              cards: ["small", "decision"].map(kind => {
                const rect = row.querySelector(`#${kind}-model-section`).getBoundingClientRect()
                return { left: rect.left, top: rect.top, bottom: rect.bottom, right: rect.right, width: rect.width }
              }),
              stackedSelectors: row.querySelectorAll(".zaq-ai-model-selector--stacked").length,
              offscreen: [...row.querySelectorAll("input,button")].filter(element => element.getBoundingClientRect().right > innerWidth + 1).length,
            })
            """)

          assert global_layout["overflow"] == false
          assert global_layout["offscreen"] == 0
          assert global_layout["stackedSelectors"] == 2
          [small, decision] = global_layout["cards"]
          for card <- global_layout["cards"], do: assert(card["right"] <= width)
          assert abs(small["width"] - decision["width"]) <= 1

          if width == 390 do
            assert decision["left"] == small["left"]
            assert decision["top"] > small["bottom"]
          else
            assert abs(decision["top"] - small["top"]) <= 1
            assert decision["left"] > small["right"]
          end

          page
          |> Page.locator("#global-model-row")
          |> Locator.screenshot!(path: Test.output_path("global-models-#{theme}-#{width}.png"))

          goto_back_office_live(page, "#{config_path()}?tab=rag")
        end
      end
    end
  end

  defp collapse_sidebar(page) do
    collapsed? =
      page
      |> Page.locator("#bo-sidebar")
      |> Locator.evaluate!(~s|element => element.classList.contains("collapsed")|)

    unless collapsed?, do: page |> Page.locator("#sidebar-toggle") |> Locator.click!()
  end

  # People access

  test "Global decision models filter, persist, reject forged models, reset and clear independently",
       %{page: page, seeded_credential: seeded_credential} do
    credential =
      create_e2e_ai_credential(page, %{
        name: "Decision catalog #{System.system_time(:millisecond)}",
        provider: "openrouter",
        endpoint: "http://127.0.0.1:4002/e2e/llm",
        auth_kind: "none"
      })

    goto_back_office_live(page, "#{config_path()}?tab=global")
    section = Page.locator(page, "#decision-model-section")
    Expect.to_contain_text!(section, "Used by workflows and enabled agent tools")
    pick_searchable_select(page, "#decision-credential-select", credential["name"])

    page
    |> Page.locator(~s|#decision-model-select li[data-select-value="liquid/d1"]|)
    |> Expect.to_have_count!(1)

    page
    |> Page.locator(~s|#decision-model-select li[data-select-value="cohere/rerank-v3.5"]|)
    |> Expect.to_have_count!(0)

    page
    |> Page.locator(~s|#decision-model-select li[data-select-value="openai/gpt-4o"]|)
    |> Expect.to_have_count!(0)

    pick_searchable_select(page, "#decision-model-select", "LiquidAI: d1")

    section
    |> Locator.get_by_role(:button, name: "Save Decision Model Settings")
    |> Locator.click!()

    page |> Page.get_by_text("Decision model settings saved.") |> Expect.to_be_visible!()
    goto_back_office_live(page, "#{config_path()}?tab=global")

    page
    |> Page.locator("#decision-credential-select input[data-select-value]")
    |> Expect.to_have_value!(to_string(credential["id"]))

    page
    |> Page.locator("#decision-model-select input[data-select-value]")
    |> Expect.to_have_value!("liquid/d1")

    page
    |> Page.locator("#decision-model-select input[data-select-value]")
    |> Locator.evaluate!(~s|input => { input.value = "cohere/rerank-v3.5" }|)

    section
    |> Locator.get_by_role(:button, name: "Save Decision Model Settings")
    |> Locator.click!()

    section
    |> Locator.locator(".zaq-field-error")
    |> Expect.to_contain_text!("is not a compatible model")

    goto_back_office_live(page, "#{config_path()}?tab=global")

    page
    |> Page.locator("#decision-model-select input[data-select-value]")
    |> Expect.to_have_value!("liquid/d1")

    small_model =
      page
      |> Page.locator(~s|#small-model-section input[name="operation_model_config[model]"]|)
      |> Locator.input_value!()

    pick_searchable_select(page, "#decision-credential-select", seeded_credential["name"])

    page
    |> Page.locator(~s|input[name="decision_model_config[model]"]|)
    |> Expect.to_have_value!("")

    page |> Page.locator("#decision-model-select") |> Expect.to_have_count!(0)
    pick_searchable_select(page, "#decision-credential-select", "Not configured")

    section
    |> Locator.get_by_role(:button, name: "Save Decision Model Settings")
    |> Locator.click!()

    page |> Page.get_by_text("Decision model settings saved.") |> Expect.to_be_visible!()
    goto_back_office_live(page, "#{config_path()}?tab=global")

    page
    |> Page.locator("#decision-model-select input[data-select-value]")
    |> Expect.to_have_value!("")

    page
    |> Page.locator("#decision-credential-select input[data-select-value]")
    |> Expect.to_have_value!("")

    page
    |> Page.locator(~s|#small-model-section input[name="operation_model_config[model]"]|)
    |> Expect.to_have_value!(small_model)

    goto_back_office_live(page, "#{config_path()}?tab=rag")

    page
    |> Page.locator("#rag-decision-section,#decision-model-section")
    |> Expect.to_have_count!(0)

    page |> Page.locator("#rag-reranking-section") |> Expect.to_be_visible!()
  end

  test "People access cold defaults, atomic save, reload, validation and keyboard layout", %{
    page: page
  } do
    switch_system_config_tab(
      page,
      sel(:tab_people_access),
      ~r/tab=people_access/,
      Page.locator(page, "#people-access-config-form")
    )

    defaults = [
      otp_validity_seconds: "300",
      otp_max_attempts: "5",
      unknown_email_attempt_limit: "10",
      unknown_email_window_seconds: "600",
      otp_send_person_limit: "5",
      otp_send_ip_limit: "20",
      otp_send_window_seconds: "900",
      session_lifetime_seconds: "604800"
    ]

    input = fn field -> Page.locator(page, "#people_access_config_#{field}") end
    "unknown_email_cooldown_seconds" |> input.() |> Expect.to_have_count!(0)

    for {field, value} <- defaults do
      field |> input.() |> Expect.to_have_value!(value)
      field |> input.() |> Expect.to_have_attribute!("step", "1")
    end

    page |> Page.locator("#session-lifetime-hint") |> Expect.to_have_text!("Default: 7 days.")

    page
    |> Page.locator("#people-access-panel")
    |> Locator.screenshot!(path: Test.output_path("people-access-desktop.png"))

    "otp_validity_seconds" |> input.() |> Locator.focus!()
    page |> Page.keyboard() |> Keyboard.press!("Tab")
    "otp_max_attempts" |> input.() |> Expect.to_be_focused!()

    updated = [
      otp_validity_seconds: "420",
      otp_max_attempts: "7",
      unknown_email_attempt_limit: "12",
      unknown_email_window_seconds: "720",
      otp_send_person_limit: "8",
      otp_send_ip_limit: "25",
      otp_send_window_seconds: "1800",
      session_lifetime_seconds: "864000"
    ]

    for {field, value} <- updated, do: field |> input.() |> Locator.fill!(value)
    wait_for_live_view_settled(page)

    expect_flash_during_action(
      page,
      "People access settings saved",
      fn -> page |> Page.locator("#people-access-save") |> Locator.click!() end,
      exact: true
    )

    goto_back_office_live(page, "#{config_path()}?tab=people_access")
    for {field, value} <- updated, do: field |> input.() |> Expect.to_have_value!(value)

    "otp_max_attempts" |> input.() |> Locator.fill!("0")
    "otp_send_ip_limit" |> input.() |> Locator.fill!("99")
    wait_for_live_view_settled(page)

    page
    |> Page.locator("#people-access-config-form .zaq-field-error")
    |> Expect.to_contain_text!("must be greater than 0")

    # Bypass native min validation to exercise authoritative server validation.
    page
    |> Page.locator("#people-access-config-form")
    |> Locator.evaluate!("(form) => { form.noValidate = true }")

    page |> Page.locator("#people-access-save") |> Locator.click!()
    wait_for_live_view_settled(page)
    "otp_send_ip_limit" |> input.() |> Expect.to_have_value!("99")
    goto_back_office_live(page, "#{config_path()}?tab=people_access")
    for {field, value} <- updated, do: field |> input.() |> Expect.to_have_value!(value)

    page |> Page.locator(sel(:tab_global)) |> Locator.click!()
    Expect.to_have_url!(page, ~r/tab=global/)
    Page.go_back!(page)
    page |> Page.locator("#people-access-config-form") |> Expect.to_be_visible!()
    "session_lifetime_seconds" |> input.() |> Expect.to_have_value!("864000")

    Page.set_viewport_size!(page, %{width: 390, height: 844})
    page |> Page.locator("#sidebar-toggle") |> Locator.click!()
    page |> Page.locator("#bo-sidebar") |> Expect.to_have_class!(~r/collapsed/)
    page |> Page.locator("#people-access-panel") |> Locator.scroll_into_view_if_needed!()
    "session_lifetime_seconds" |> input.() |> Expect.to_be_visible!()
    panel = page |> Page.locator("#people-access-panel") |> Locator.bounding_box!()
    assert panel.width > 200
    assert panel.x + panel.width <= 390

    page
    |> Page.locator("#people-access-panel")
    |> Locator.screenshot!(path: Test.output_path("people-access-mobile.png"))
  end
end

defmodule Zaq.E2EPw.SystemConfigRetrievalTest do
  use Zaq.E2EPw.SystemConfigTest.Shared

  alias Playwright.Clock

  describe "Retrieval settings" do
    setup %{page: page} do
      open_retrieval_settings(page)
      :ok
    end

    test "renders all required form fields", %{page: page} do
      cosine_distance =
        Page.locator(page, ~s|input[name="retrieval_config[max_cosine_distance]"]|)

      Expect.to_be_visible!(cosine_distance)
      Expect.to_have_attribute!(cosine_distance, "min", "0")
      Expect.to_have_attribute!(cosine_distance, "max", "2")
    end

    test "successful retrieval save shows flash message", %{page: page} do
      expect_flash_during_action(page, "Retrieval settings saved.", fn ->
        page |> Page.get_by_role(:button, name: "Save Retrieval Settings") |> Locator.click!()
      end)
    end

    test "flash auto-dismisses without user interaction", %{page: page} do
      page |> Page.clock() |> Clock.install!()
      page |> Page.clock() |> Clock.pause_at!(System.system_time(:millisecond) + 1_000)
      page |> Page.get_by_role(:button, name: "Save Retrieval Settings") |> Locator.click!()
      page |> Page.get_by_text("Retrieval settings saved.") |> Expect.to_be_visible!()
      # Run the real auto-dismiss timer without relying on CI wall-clock scheduling.
      # Must disappear on its own: do not click dismiss.
      page |> Page.clock() |> Clock.run_for!(5_000)

      page
      |> Page.get_by_text("Retrieval settings saved.")
      |> Expect.not_()
      |> Expect.to_be_visible!(timeout: 10_000)
    end

    for boundary <- ["0", "2"] do
      @boundary boundary

      test "cosine distance boundary #{boundary} saves and persists", %{page: page} do
        boundary = @boundary
        field = Page.locator(page, ~s|input[name="retrieval_config[max_cosine_distance]"]|)
        Locator.fill!(field, boundary)
        Locator.press!(field, "Tab")
        wait_for_live_view_settled(page)

        expect_flash_during_action(page, "Retrieval settings saved.", fn ->
          page |> Page.get_by_role(:button, name: "Save Retrieval Settings") |> Locator.click!()
        end)

        open_retrieval_settings(page)

        page
        |> Page.locator(~s|input[name="retrieval_config[max_cosine_distance]"]|)
        |> Expect.to_have_js_property!("valueAsNumber", String.to_integer(boundary))
      end
    end

    for invalid <- ["-0.01", "2.01"] do
      @invalid invalid

      test "cosine distance #{invalid} is rejected without changing persisted settings", %{
        page: page
      } do
        invalid = @invalid
        field = Page.locator(page, ~s|input[name="retrieval_config[max_cosine_distance]"]|)
        persisted = Locator.evaluate!(field, "input => input.valueAsNumber")
        Locator.fill!(field, invalid)
        Locator.press!(field, "Tab")
        wait_for_live_view_settled(page)
        page |> Page.get_by_role(:button, name: "Save Retrieval Settings") |> Locator.click!()

        page
        |> Page.get_by_text("Retrieval settings saved.")
        |> Expect.not_()
        |> Expect.to_be_visible!()

        open_retrieval_settings(page)

        page
        |> Page.locator(~s|input[name="retrieval_config[max_cosine_distance]"]|)
        |> Expect.to_have_js_property!("valueAsNumber", persisted)
      end
    end
  end
end

defmodule Zaq.E2EPw.SystemConfigEmbeddingTest do
  use Zaq.E2EPw.SystemConfigTest.Shared

  describe "Embedding tab" do
    setup %{page: page, seeded_credential: seeded_credential} do
      page |> Page.locator(sel(:tab_embedding)) |> Locator.click!()
      page |> Page.locator(sel(:embedding_form)) |> Expect.to_be_visible!()
      wait_for_live_view_settled(page)
      pick_searchable_select(page, "#embedding-credential-select", seeded_credential["name"])
      wait_for_live_view_settled(page, timeout: if(ci?(), do: 20_000, else: 10_000))
      :ok
    end

    test "renders all required form fields", %{page: page} do
      page
      |> Page.locator("#embedding-credential-select [data-select-trigger]")
      |> Expect.to_be_visible!()

      page
      |> Page.locator(~s|input[name="embedding_config[dimension]"]|)
      |> Expect.to_be_visible!()

      page
      |> Page.locator(~s|input[name="embedding_config[chunk_min_tokens]"]|)
      |> Expect.to_be_visible!()

      page
      |> Page.locator(~s|input[name="embedding_config[chunk_max_tokens]"]|)
      |> Expect.to_be_visible!()
    end

    test "credential selector opens and accepts option filtering", %{
      page: page,
      seeded_credential: seeded_credential
    } do
      page |> Page.locator(sel(:tab_embedding)) |> Locator.click!()
      page |> Page.locator(sel(:embedding_form)) |> Expect.to_be_visible!()

      pick_searchable_select(page, "#embedding-credential-select", seeded_credential["name"])

      page
      |> Page.locator("#embedding-credential-select [data-select-label]")
      |> Expect.to_contain_text!(seeded_credential["name"])
    end

    # Lock / Unlock

    test "model is locked by default: unlock button present, dimension disabled", %{page: page} do
      page |> Page.locator(sel(:unlock_trigger)) |> Expect.to_be_visible!()

      page
      |> Page.locator(~s|input[name="embedding_config[dimension]"]|)
      |> Expect.to_be_disabled!()
    end

    test "unlock modal opens on Unlock click", %{page: page} do
      page |> Page.locator(sel(:unlock_trigger)) |> Locator.click!()

      # Use heading role to avoid strict-mode violation from case-insensitive substring match on <p>
      page
      |> Page.get_by_role(:heading, name: "Unlock Model Selection")
      |> Expect.to_be_visible!()

      page
      |> Page.get_by_text("permanently delete all existing embeddings")
      |> Expect.to_be_visible!()
    end

    test "cancel unlock: modal closes and model stays locked", %{page: page} do
      page |> Page.locator(sel(:unlock_trigger)) |> Locator.click!()

      page
      |> Page.get_by_role(:heading, name: "Unlock Model Selection")
      |> Expect.to_be_visible!()

      page |> Page.locator(sel(:cancel_unlock)) |> Locator.click!()

      page
      |> Page.get_by_role(:heading, name: "Unlock Model Selection")
      |> Expect.not_()
      |> Expect.to_be_visible!()

      page |> Page.locator(sel(:unlock_trigger)) |> Expect.to_be_visible!()

      page
      |> Page.locator(~s|input[name="embedding_config[dimension]"]|)
      |> Expect.to_be_disabled!()
    end

    test "confirm unlock: modal closes, unlock button gone, dimension enabled", %{page: page} do
      page |> Page.locator(sel(:unlock_trigger)) |> Locator.click!()
      page |> Page.locator(sel(:confirm_unlock)) |> Locator.click!()

      page
      |> Page.get_by_role(:heading, name: "Unlock Model Selection")
      |> Expect.not_()
      |> Expect.to_be_visible!()

      page |> Page.locator(sel(:unlock_trigger)) |> Expect.not_() |> Expect.to_be_visible!()

      page
      |> Page.locator(~s|input[name="embedding_config[dimension]"]|)
      |> Expect.not_()
      |> Expect.to_be_disabled!()
    end

    # NOTE: handle_params only assigns active_tab: it does NOT reload the embedding form.
    # Only a full page navigation (mount) resets embedding_locked to true.
    test "full page reload re-engages the lock after it was unlocked", %{page: page} do
      page |> Page.locator(sel(:unlock_trigger)) |> Locator.click!()
      page |> Page.locator(sel(:confirm_unlock)) |> Locator.click!()
      page |> Page.locator(sel(:unlock_trigger)) |> Expect.not_() |> Expect.to_be_visible!()

      # Full reload: triggers mount -> load_embedding_form -> embedding_locked: true
      goto_back_office_live(page, "#{config_path()}?tab=embedding")

      page |> Page.locator(sel(:unlock_trigger)) |> Expect.to_be_visible!()

      page
      |> Page.locator(~s|input[name="embedding_config[dimension]"]|)
      |> Expect.to_be_disabled!()
    end

    # Save without model change
    # NOTE: Changing endpoint while locked triggers phx-change, which excludes the disabled
    # model input from params -> params["model"] = nil != saved_model -> model_changed = true.
    # To test a genuinely non-destructive save, submit without triggering phx-change.

    test "saving with current config (no field change) succeeds without confirm modal", %{
      page: page
    } do
      # model_changed is false at mount; no phx-change fired -> goes straight to do_save_embedding
      expect_flash_during_action(page, "Embedding settings saved.", fn ->
        page |> Page.get_by_role(:button, name: "Save Embedding Settings") |> Locator.click!()
      end)

      page
      |> Page.get_by_role(:heading, name: "Delete All Embeddings?")
      |> Expect.not_()
      |> Expect.to_be_visible!()
    end

    # Destructive save flow

    test "changing dimension after unlock marks save button red and triggers confirm modal", %{
      page: page
    } do
      page |> Page.locator(sel(:unlock_trigger)) |> Locator.click!()
      page |> Page.locator(sel(:confirm_unlock)) |> Locator.click!()

      dim_input = Page.locator(page, ~s|input[name="embedding_config[dimension]"]|)
      new_dim = different_dimension(page)
      Locator.fill!(dim_input, to_string(new_dim))
      Locator.press!(dim_input, "Tab")

      save_btn = Page.get_by_role(page, :button, name: "Save Embedding Settings")
      # Wait for server to process validate_embedding and set model_changed: true
      Expect.to_have_class!(save_btn, ~r/zaq-btn-danger/)

      Locator.click!(save_btn)

      page
      |> Page.get_by_role(:heading, name: "Delete All Embeddings?")
      |> Expect.to_be_visible!()

      page |> Page.get_by_text("This cannot be undone") |> Expect.to_be_visible!()
    end

    test "cancel destructive save: modal closes, form intact, no success flash", %{page: page} do
      page |> Page.locator(sel(:unlock_trigger)) |> Locator.click!()
      page |> Page.locator(sel(:confirm_unlock)) |> Locator.click!()

      dim_input = Page.locator(page, ~s|input[name="embedding_config[dimension]"]|)
      new_dim = different_dimension(page)
      Locator.fill!(dim_input, to_string(new_dim))
      Locator.press!(dim_input, "Tab")

      page |> Page.get_by_role(:button, name: "Save Embedding Settings") |> Locator.click!()

      page
      |> Page.get_by_role(:heading, name: "Delete All Embeddings?")
      |> Expect.to_be_visible!()

      page |> Page.locator(sel(:cancel_save)) |> Locator.click!()

      page
      |> Page.get_by_role(:heading, name: "Delete All Embeddings?")
      |> Expect.not_()
      |> Expect.to_be_visible!()

      page |> Page.locator(sel(:embedding_form)) |> Expect.to_be_visible!()

      page
      |> Page.get_by_text("Embedding settings saved.")
      |> Expect.not_()
      |> Expect.to_be_visible!()
    end

    test "confirm destructive save: modal closes and save succeeds", %{page: page} do
      page |> Page.locator(sel(:unlock_trigger)) |> Locator.click!()
      page |> Page.locator(sel(:confirm_unlock)) |> Locator.click!()

      dim_input = Page.locator(page, ~s|input[name="embedding_config[dimension]"]|)
      new_dim = different_dimension(page)
      Locator.fill!(dim_input, to_string(new_dim))
      Locator.press!(dim_input, "Tab")

      page |> Page.get_by_role(:button, name: "Save Embedding Settings") |> Locator.click!()

      page
      |> Page.get_by_role(:heading, name: "Delete All Embeddings?")
      |> Expect.to_be_visible!()

      expect_flash_during_action(page, "Embedding settings saved.", fn ->
        page |> Page.locator(sel(:confirm_save)) |> Locator.click!()
      end)

      page
      |> Page.get_by_role(:heading, name: "Delete All Embeddings?")
      |> Expect.not_()
      |> Expect.to_be_visible!()
    end

    # Validation: required & numeric

    test "dimension of 0 is rejected after unlock", %{page: page} do
      page |> Page.locator(sel(:unlock_trigger)) |> Locator.click!()
      page |> Page.locator(sel(:confirm_unlock)) |> Locator.click!()

      dim_input = Page.locator(page, ~s|input[name="embedding_config[dimension]"]|)
      Locator.fill!(dim_input, "0")
      Locator.press!(dim_input, "Tab")
      page |> Page.get_by_role(:button, name: "Save Embedding Settings") |> Locator.click!()

      # If the confirm modal appears (model_changed = true), proceed through it
      modal = Page.get_by_role(page, :heading, name: "Delete All Embeddings?")

      if Locator.is_visible!(modal) do
        page |> Page.locator(sel(:confirm_save)) |> Locator.click!()
      end

      page
      |> Page.get_by_text("Embedding settings saved.")
      |> Expect.not_()
      |> Expect.to_be_visible!()
    end

    test "chunk_min_tokens equal to chunk_max_tokens shows order error", %{page: page} do
      min_input = Page.locator(page, ~s|input[name="embedding_config[chunk_min_tokens]"]|)
      max_input = Page.locator(page, ~s|input[name="embedding_config[chunk_max_tokens]"]|)

      Locator.fill!(min_input, "500")
      Locator.press!(min_input, "Tab")
      Locator.fill!(max_input, "500")
      Locator.press!(max_input, "Tab")

      page |> Page.get_by_role(:button, name: "Save Embedding Settings") |> Locator.click!()
      page |> Page.get_by_text("must be greater than min tokens") |> Expect.to_be_visible!()

      page
      |> Page.get_by_text("Embedding settings saved.")
      |> Expect.not_()
      |> Expect.to_be_visible!()
    end

    test "chunk_min_tokens greater than chunk_max_tokens shows order error", %{page: page} do
      min_input = Page.locator(page, ~s|input[name="embedding_config[chunk_min_tokens]"]|)
      max_input = Page.locator(page, ~s|input[name="embedding_config[chunk_max_tokens]"]|)

      Locator.fill!(min_input, "900")
      Locator.press!(min_input, "Tab")
      Locator.fill!(max_input, "400")
      Locator.press!(max_input, "Tab")

      page |> Page.get_by_role(:button, name: "Save Embedding Settings") |> Locator.click!()
      page |> Page.get_by_text("must be greater than min tokens") |> Expect.to_be_visible!()

      page
      |> Page.get_by_text("Embedding settings saved.")
      |> Expect.not_()
      |> Expect.to_be_visible!()
    end

    test "chunk_min_tokens of 0 is rejected (must be > 0)", %{page: page} do
      min_input = Page.locator(page, ~s|input[name="embedding_config[chunk_min_tokens]"]|)
      Locator.fill!(min_input, "0")
      Locator.press!(min_input, "Tab")
      page |> Page.get_by_role(:button, name: "Save Embedding Settings") |> Locator.click!()

      page
      |> Page.get_by_text("Embedding settings saved.")
      |> Expect.not_()
      |> Expect.to_be_visible!()
    end

    # API key persistence

    test "changing credential saves and persists after page reload", %{
      page: page,
      seeded_credential: seeded_credential
    } do
      page |> Page.locator(sel(:tab_embedding)) |> Locator.click!()
      pick_searchable_select(page, "#embedding-credential-select", seeded_credential["name"])

      expect_flash_during_action(page, "Embedding settings saved.", fn ->
        page |> Page.get_by_role(:button, name: "Save Embedding Settings") |> Locator.click!()
      end)

      # Full reload: triggers mount -> load_embedding_form -> reads from DB
      goto_back_office_live(page, "#{config_path()}?tab=embedding")
      page |> Page.locator(sel(:embedding_form)) |> Expect.to_be_visible!()

      page
      |> Page.locator("#embedding-credential-select [data-select-label]")
      |> Expect.to_contain_text!(seeded_credential["name"])
    end
  end
end

defmodule Zaq.E2EPw.SystemConfigImageToTextTest do
  use Zaq.E2EPw.SystemConfigTest.Shared

  describe "Image to Text tab" do
    setup %{page: page, seeded_credential: seeded_credential} do
      page |> Page.locator(sel(:tab_image_to_text)) |> Locator.click!()
      page |> Page.locator(sel(:image_to_text_form)) |> Expect.to_be_visible!()
      wait_for_live_view_settled(page)
      pick_searchable_select(page, "#image-to-text-credential-select", seeded_credential["name"])
      wait_for_live_view_settled(page, timeout: if(ci?(), do: 20_000, else: 10_000))
      :ok
    end

    test "renders credential and model fields", %{page: page} do
      page
      |> Page.locator("#image-to-text-credential-select [data-select-trigger]")
      |> Expect.to_be_visible!()

      text_input = Page.locator(page, ~s|input[type="text"][name="image_to_text_config[model]"]|)
      dropdown = Page.locator(page, "#image-to-text-model-select [data-select-trigger]")
      expect_either_visible(text_input, dropdown)
    end

    test "credential selector opens and accepts option filtering", %{
      page: page,
      seeded_credential: seeded_credential
    } do
      page |> Page.locator(sel(:tab_image_to_text)) |> Locator.click!()
      page |> Page.locator(sel(:image_to_text_form)) |> Expect.to_be_visible!()

      pick_searchable_select(
        page,
        "#image-to-text-credential-select",
        seeded_credential["name"]
      )

      page
      |> Page.locator("#image-to-text-credential-select [data-select-label]")
      |> Expect.to_contain_text!(seeded_credential["name"])
    end

    test "successful save shows flash message", %{
      page: page,
      seeded_credential: seeded_credential
    } do
      page |> Page.locator(sel(:tab_image_to_text)) |> Locator.click!()

      pick_searchable_select(
        page,
        "#image-to-text-credential-select",
        seeded_credential["name"]
      )

      expect_flash_during_action(page, "Image-to-Text settings saved.", fn ->
        page |> Page.get_by_role(:button, name: "Save Image to Text Settings") |> Locator.click!()
      end)
    end

    test "either model text input or model dropdown is present", %{page: page} do
      text_input = Page.locator(page, ~s|input[name="image_to_text_config[model]"]|)
      dropdown = Page.locator(page, "#image-to-text-model-select")
      expect_either_visible(text_input, dropdown)
    end

    # API key persistence

    test "changing credential saves and persists after page reload", %{
      page: page,
      seeded_credential: seeded_credential
    } do
      page |> Page.locator(sel(:tab_image_to_text)) |> Locator.click!()

      pick_searchable_select(
        page,
        "#image-to-text-credential-select",
        seeded_credential["name"]
      )

      expect_flash_during_action(page, "Image-to-Text settings saved.", fn ->
        page |> Page.get_by_role(:button, name: "Save Image to Text Settings") |> Locator.click!()
      end)

      # Full reload: triggers mount -> load_image_to_text_form -> reads from DB
      goto_back_office_live(page, "#{config_path()}?tab=image_to_text")
      page |> Page.locator(sel(:image_to_text_form)) |> Expect.to_be_visible!()

      page
      |> Page.locator("#image-to-text-credential-select [data-select-label]")
      |> Expect.to_contain_text!(seeded_credential["name"])
    end
  end
end

defmodule Zaq.E2EPw.SystemConfigAiCredentialsTest do
  use Zaq.E2EPw.SystemConfigTest.Shared

  describe "AI Credentials tab" do
    setup %{page: page} do
      page |> Page.locator(sel(:tab_ai_credentials)) |> Locator.click!()
      Expect.to_have_url!(page, ~r/tab=ai_credentials/)
      page |> Page.get_by_role(:heading, name: "AI Credentials") |> Expect.to_be_visible!()
      :ok
    end

    test "create credential shows success and renders in list", %{page: page} do
      credential = create_ai_credential(page, provider: "Custom", endpoint: e2e_endpoint())

      row =
        page
        |> Page.locator(~s|button[phx-click="edit_ai_credential"]|)
        |> Locator.filter(has_text: credential.name)
        |> Locator.first()

      Expect.to_be_visible!(row)
      Expect.to_contain_text!(row, "Non-sovereign")
    end

    test "no-auth AI credential and linked Auth Credential reflect edits in either form", %{
      page: page
    } do
      name = "E2E No Auth #{System.system_time(:millisecond)}"
      page |> Page.locator(~s|[phx-click="new_ai_credential"]|) |> Locator.click!()
      page |> Page.locator(~s|input[name="ai_credential[name]"]|) |> Locator.fill!(name)
      pick_searchable_select(page, "#ai-credential-provider-select", "Custom")

      page
      |> Page.locator(~s|input[name="ai_credential[endpoint]"]|)
      |> Locator.fill!(e2e_endpoint())

      page
      |> Page.locator(~s|select[name="ai_credential[auth_mode]"]|)
      |> Locator.select_option!("none")

      page |> Page.locator("#ai-credential-api-key-input") |> Expect.to_have_count!(0)

      page
      |> Page.locator(~s|[name="ai_credential[personal_credential_policy]"]|)
      |> Expect.to_have_count!(0)

      page
      |> Page.locator("#ai-credential-modal")
      |> Locator.get_by_role(:button, name: "Save credential")
      |> Locator.click!()

      ai_row =
        page
        |> Page.locator(~s|button[phx-click="edit_ai_credential"]|)
        |> Locator.filter(has_text: name)

      Expect.to_contain_text!(ai_row, "No authentication")
      goto_back_office_live(page, "#{config_path()}?tab=auth_credentials")

      auth_row =
        page
        |> Page.get_by_text("AI: #{name}", exact: true)
        |> Locator.locator("..")
        |> Locator.locator("..")

      Expect.to_contain_text!(auth_row, "custom · none")
      auth_row |> Locator.get_by_role(:button, name: "Edit") |> Locator.click!()

      page
      |> Page.locator(~s|select[name="credential[auth_kind]"]|)
      |> Expect.to_have_value!("none")

      page |> Page.locator(~s|[name="credential[api_key]"]|) |> Expect.to_have_count!(0)

      page
      |> Page.locator(~s|select[name="credential[auth_kind]"]|)
      |> Locator.select_option!("api_key")

      page |> Page.locator(~s|[name="credential[api_key]"]|) |> Locator.fill!("e2e-linked-key")

      page
      |> Page.locator("#edit-connect-credential-modal")
      |> Locator.get_by_role(:button, name: "Save", exact: true)
      |> Locator.click!()

      Expect.to_contain_text!(auth_row, "custom · api_key")

      goto_back_office_live(page, "#{config_path()}?tab=ai_credentials")
      Expect.to_contain_text!(ai_row, "API key configured")
      Locator.click!(ai_row)

      page
      |> Page.locator(~s|select[name="ai_credential[auth_mode]"]|)
      |> Expect.to_have_value!("api_key")

      page
      |> Page.locator(~s|select[name="ai_credential[auth_mode]"]|)
      |> Locator.select_option!("none")

      page
      |> Page.locator("#ai-credential-modal")
      |> Locator.get_by_role(:button, name: "Save credential")
      |> Locator.click!()

      Expect.to_contain_text!(ai_row, "No authentication")

      goto_back_office_live(page, "#{config_path()}?tab=auth_credentials")
      Expect.to_contain_text!(auth_row, "custom · none")
      auth_row |> Locator.get_by_role(:button, name: "View grants") |> Locator.click!()
      page |> Page.get_by_text("No grants for this credential.") |> Expect.to_be_visible!()
    end

    test "new API-key credential requires a key, while blank edit retains the saved key", %{
      page: page
    } do
      name = "E2E API validation #{System.system_time(:millisecond)}"
      page |> Page.locator(~s|[phx-click="new_ai_credential"]|) |> Locator.click!()
      page |> Page.locator(~s|input[name="ai_credential[name]"]|) |> Locator.fill!(name)
      pick_searchable_select(page, "#ai-credential-provider-select", "Custom")

      page
      |> Page.locator(~s|input[name="ai_credential[endpoint]"]|)
      |> Locator.fill!(e2e_endpoint())

      page
      |> Page.locator("#ai-credential-modal")
      |> Locator.get_by_role(:button, name: "Save credential")
      |> Locator.click!()

      page
      |> Page.locator("#ai-credential-modal")
      |> Expect.to_contain_text!("enter an API key or choose No authentication")

      page |> Page.locator("#ai-credential-api-key-input") |> Locator.fill!("e2e-preserved-key")

      page
      |> Page.locator("#ai-credential-modal")
      |> Locator.get_by_role(:button, name: "Save credential")
      |> Locator.click!()

      ai_row =
        page
        |> Page.locator(~s|button[phx-click="edit_ai_credential"]|)
        |> Locator.filter(has_text: name)

      Expect.to_contain_text!(ai_row, "API key configured")

      Locator.click!(ai_row)

      page
      |> Page.locator(~s|input[name="ai_credential[endpoint]"]|)
      |> Locator.fill!("#{e2e_endpoint()}/updated")

      page |> Page.locator("#ai-credential-api-key-input") |> Locator.fill!("")
      page |> Page.locator("#ai-credential-api-key-input") |> Expect.to_have_value!("")

      page
      |> Page.locator("#ai-credential-modal")
      |> Locator.get_by_role(:button, name: "Save credential")
      |> Locator.click!()

      goto_back_office_live(page, "#{config_path()}?tab=ai_credentials")
      Expect.to_contain_text!(ai_row, "API key configured")

      goto_back_office_live(page, "#{config_path()}?tab=auth_credentials")

      auth_row =
        page
        |> Page.get_by_text("AI: #{name}", exact: true)
        |> Locator.locator("..")
        |> Locator.locator("..")

      Expect.to_contain_text!(auth_row, "custom · api_key")
      auth_row |> Locator.get_by_role(:button, name: "View grants") |> Locator.click!()
      page |> Page.get_by_text("No grants for this credential.") |> Expect.to_have_count!(0)

      page
      |> Page.locator("#connect-grants-modal")
      |> Expect.to_contain_text!("owner=org:nil · status=active")
    end

    test "OAuth-only provider cannot select no authentication", %{page: page} do
      page |> Page.locator(~s|[phx-click="new_ai_credential"]|) |> Locator.click!()
      pick_searchable_select(page, "#ai-credential-provider-select", "OpenAI Codex")

      page
      |> Page.locator(~s|select[name="ai_credential[auth_mode]"]|)
      |> Expect.to_be_disabled!()

      page
      |> Page.locator(~s|input[name="ai_credential[auth_mode]"]|)
      |> Expect.to_have_value!("oauth2")

      page
      |> Page.locator(~s|select[name="ai_credential[auth_mode]"] option[value="none"]|)
      |> Expect.to_have_count!(0)
    end

    test "personal policy and masked global API-key grant persist", %{page: page} do
      required = %{name: "E2E Required Personal #{System.system_time(:millisecond)}"}
      page |> Page.locator(~s|[phx-click="new_ai_credential"]|) |> Locator.click!()
      page |> Page.locator(~s|input[name="ai_credential[name]"]|) |> Locator.fill!(required.name)
      pick_searchable_select(page, "#ai-credential-provider-select", "Custom")

      page
      |> Page.locator(~s|input[name="ai_credential[endpoint]"]|)
      |> Locator.fill!(e2e_endpoint())

      page
      |> Page.locator(~s|select[name="ai_credential[auth_mode]"]|)
      |> Locator.select_option!("oauth2")

      page
      |> Page.locator(~s|textarea[name="ai_credential[metadata]"]|)
      |> Locator.fill!(~s|{"client_id":"e2e-client"}|)

      page
      |> Page.locator(~s|[name="ai_credential[personal_credential_policy]"]|)
      |> Locator.select_option!("required")

      expect_flash_during_action(page, "AI credential saved.", fn ->
        page
        |> Page.locator("#ai-credential-modal")
        |> Locator.get_by_role(:button, name: "Save credential")
        |> Locator.click!()
      end)

      required_row =
        page
        |> Page.locator(~s|button[phx-click="edit_ai_credential"]|)
        |> Locator.filter(has_text: required.name)

      Expect.to_contain_text!(required_row, "No bearer grant")
      Locator.click!(required_row)

      page
      |> Page.locator(~s|[name="ai_credential[personal_credential_policy]"]|)
      |> Expect.to_have_value!("required")

      page |> Page.get_by_text("Without a global credential") |> Expect.to_be_visible!()

      page
      |> Page.locator("#ai-credential-modal button[aria-label='Close dialog']")
      |> Locator.click!()

      global_secret = "GLOBAL-POLICY-SECRET-#{System.system_time(:millisecond)}"

      optional =
        create_ai_credential(page,
          name: "E2E Optional Personal #{System.system_time(:millisecond)}",
          provider: "Custom",
          endpoint: e2e_endpoint(),
          api_key: global_secret,
          personal_credential_policy: "optional"
        )

      optional_row =
        page
        |> Page.locator(~s|button[phx-click="edit_ai_credential"]|)
        |> Locator.filter(has_text: optional.name)

      Expect.to_contain_text!(optional_row, "API key configured")
      page |> Page.locator("body") |> Expect.not_() |> Expect.to_contain_text!(global_secret)

      goto_back_office_live(page, "#{config_path()}?tab=ai_credentials")
      Locator.click!(optional_row)

      page
      |> Page.locator(~s|[name="ai_credential[personal_credential_policy]"]|)
      |> Expect.to_have_value!("optional")

      page
      |> Page.locator("#ai-credential-api-key-input")
      |> Expect.to_have_attribute!("style", ~r/-webkit-text-security: disc/)

      page |> Page.locator("body") |> Expect.not_() |> Expect.to_contain_text!(global_secret)
    end

    test "api key is masked by default; show/hide toggles the mask", %{page: page} do
      page |> Page.locator(~s|[phx-click="new_ai_credential"]|) |> Locator.click!()
      page |> Page.locator(sel(:ai_credential_form)) |> Expect.to_be_visible!()

      input = Page.locator(page, "#ai-credential-api-key-input")
      show_btn = Page.locator(page, "#ai-credential-api-key-show")
      hide_btn = Page.locator(page, "#ai-credential-api-key-hide")

      Expect.to_have_attribute!(input, "style", ~r/-webkit-text-security: disc/)
      Expect.to_have_class!(hide_btn, ~r/hidden/)

      Locator.click!(show_btn)
      input |> Expect.not_() |> Expect.to_have_attribute!("style", ~r/-webkit-text-security/)
      Expect.to_have_class!(show_btn, ~r/hidden/)
      hide_btn |> Expect.not_() |> Expect.to_have_class!(~r/hidden/)

      Locator.click!(hide_btn)
      Expect.to_have_attribute!(input, "style", ~r/-webkit-text-security: disc/)
      Expect.to_have_class!(hide_btn, ~r/hidden/)
      show_btn |> Expect.not_() |> Expect.to_have_class!(~r/hidden/)
    end

    test "new credential can be selected for the Small model and saved", %{page: page} do
      credential = create_ai_credential(page, provider: "Custom", endpoint: e2e_endpoint())

      page |> Page.locator(sel(:tab_global)) |> Locator.click!()
      wait_for_live_view_settled(page)
      pick_searchable_select(page, "#small-credential-select", credential.name)
      wait_for_live_view_settled(page)
      form = Page.locator(page, "#small-model-form")
      model = Locator.locator(form, ~s|input[name="operation_model_config[model]"]|)
      Locator.fill!(model, "e2e-fake")
      Locator.press!(model, "Tab")
      wait_for_live_view_settled(page)
      form |> Locator.get_by_text("can't be blank", exact: true) |> Expect.to_have_count!(0)

      expect_flash_during_action(page, "Model settings saved.", fn ->
        page |> Page.get_by_role(:button, name: "Save Small Model Settings") |> Locator.click!()
      end)
    end
  end
end

defmodule Zaq.E2EPw.SystemConfigGlobalTest do
  use Zaq.E2EPw.SystemConfigTest.Shared

  describe "Global tab" do
    setup %{page: page} do
      page |> Page.locator(sel(:tab_global)) |> Locator.click!()
      Expect.to_have_url!(page, ~r/tab=global/)
      page |> Page.get_by_role(:heading, name: "Global") |> Expect.to_be_visible!()
      :ok
    end

    test "renders Language and TimeZone fields", %{page: page} do
      page |> Page.locator("#global-language-select") |> Expect.to_be_visible!()
      page |> Page.locator("#global-timezone-select") |> Expect.to_be_visible!()

      page
      |> Page.locator("#global-language-select li[data-select-value='en']")
      |> Expect.to_be_attached!()

      page
      |> Page.locator("#global-language-select li[data-select-value='fr']")
      |> Expect.to_be_attached!()
    end

    test "French language option is disabled", %{page: page} do
      page
      |> Page.locator("#global-language-select li[data-select-value='fr']")
      |> Expect.to_have_attribute!("data-select-disabled", "true")

      selected = Page.locator(page, "#global-language-select input[data-select-value]")
      value = Locator.input_value!(selected)
      page |> Page.locator("#global-language-select-trigger") |> Locator.click!()

      page
      |> Page.locator("#global-language-select li[data-select-value='fr']")
      |> Locator.click!()

      Expect.to_have_value!(selected, value)
      page |> Page.locator("#global-language-select-trigger") |> Locator.click!()
    end

    test "saves language and persists after page reload", %{page: page} do
      pick_searchable_select(page, "#global-language-select", "English", searchable: false)

      expect_flash_during_action(page, "Language saved.", fn ->
        page
        |> Page.locator(~s|form[phx-submit="save_global_language"] button[type="submit"]|)
        |> Locator.click!()
      end)

      goto_back_office_live(page, "#{config_path()}?tab=global")

      page
      |> Page.locator("#global-language-select input[data-select-value]")
      |> Expect.to_have_value!("en")
    end

    test "shows GMT offsets in timezone dropdown", %{page: page} do
      options = Page.locator(page, "#global-timezone-select li[data-select-option]")
      Expect.to_contain_text!(options, ["GMT-12:00", "GMT+00:00", "GMT+14:00"])
    end

    test "saves timezone and persists after page reload", %{page: page} do
      pick_searchable_select(page, "#global-timezone-select", "GMT+03:00", searchable: false)

      expect_flash_during_action(page, "Timezone saved.", fn ->
        page
        |> Page.locator(~s|form[phx-submit="save_global_timezone"] button[type="submit"]|)
        |> Locator.click!()
      end)

      goto_back_office_live(page, "#{config_path()}?tab=global")

      page
      |> Page.locator("#global-timezone-select input[data-select-value]")
      |> Expect.to_have_value!("GMT+03:00")
    end
  end
end
