defmodule Zaq.E2EPw.AiModelSelectorTest do
  use Zaq.E2EPw.Case

  import Zaq.E2EPw.BO

  @selectors [
    %{id: "small", tab: "global", key: "global.small_model", form: "small-model-form"},
    %{id: "embedding", tab: "rag", key: "embedding", form: "embedding-config-form"},
    %{id: "image-to-text", tab: "rag", key: "image_to_text", form: "image-to-text-config-form"},
    %{id: "translation", tab: "rag", key: "rag.translation", form: "translation-model-form"},
    %{id: "rag-reranking", tab: "rag", key: "rag.reranking", form: "rag-reranking-form"},
    %{id: "decision", tab: "global", key: "global.decision_model", form: "decision-model-form"}
  ]

  # Shared AI model selector
  setup %{page: page, request: request} do
    reset_e2e_state(request)
    login_to_back_office(page)
    :ok
  end

  defp sidebar_collapsed?(page) do
    page
    |> Page.locator("#bo-sidebar")
    |> Locator.evaluate!("el => el.classList.contains('collapsed')")
  end

  defp expect_model_row_layout(selector) do
    Expect.poll!(
      fn ->
        Locator.evaluate!(selector, """
        root => {
          const provider = root.querySelector(".zaq-ai-model-provider").getBoundingClientRect()
          const row = root.querySelector(".zaq-ai-model-row")
          const model = root.querySelector(".zaq-ai-model-field input[type='text']:not([data-select-search]), .zaq-ai-model-field [data-select-trigger]").getBoundingClientRect()
          const modalities = root.querySelector(".zaq-ai-model-modalities").getBoundingClientRect()
          const stacked = getComputedStyle(row).display !== "contents"

          return {
            beside: modalities.left >= model.right,
            aligned: modalities.top < model.bottom && modalities.bottom > model.top,
            equalWidth: !stacked || Math.abs(provider.width - row.getBoundingClientRect().width) < 1,
            providerAbove: !stacked || provider.bottom <= model.top,
            withinViewport: modalities.right <= innerWidth + 1,
          }
        }
        """)
      end,
      &assert(
        &1 == %{
          "beside" => true,
          "aligned" => true,
          "equalWidth" => true,
          "providerAbove" => true,
          "withinViewport" => true
        }
      )
    )
  end

  for selection <- @selectors do
    @selection selection

    @tag timeout: 90_000
    test "#{selection.id} supports manual custom models, inline modalities and save/reload", %{
      page: page,
      request: request
    } do
      selection = @selection

      credential =
        create_e2e_ai_credential(page, %{
          name: "Shared selector #{selection.id}",
          provider: "Custom",
          endpoint: "http://localhost:11434/v1",
          api_key: "e2e-selector-key"
        })

      set_e2e_system_config(
        request,
        "#{selection.key}.credential_id",
        to_string(credential["id"])
      )

      set_e2e_system_config(request, "#{selection.key}.model", "private/original")
      goto_back_office_live(page, "/bo/system-config?tab=#{selection.tab}")

      form = Page.locator(page, "##{selection.form}")
      selector = Locator.locator(form, ".zaq-ai-model-selector")
      model = Page.locator(page, "##{selection.id}-model-input")
      Expect.to_have_value!(model, "private/original")
      page |> Page.locator("##{selection.id}-model-select") |> Expect.to_have_count!(0)

      selector
      |> Locator.get_by_role(:button, name: "Input: Unknown", exact: true)
      |> Expect.to_be_visible!()

      selector
      |> Locator.get_by_role(:button, name: "Output: Unknown", exact: true)
      |> Expect.to_be_visible!()

      for theme <- ["light", "dark"] do
        page
        |> Page.get_by_role(:button, name: "Use #{theme} theme", exact: true)
        |> Locator.click!()

        for width <- [1280, 390] do
          Page.set_viewport_size!(page, %{width: width, height: 900})

          if width == 390 and not sidebar_collapsed?(page) do
            page |> Page.locator("#sidebar-toggle") |> Locator.click!()
            page |> Page.locator("#bo-main") |> Expect.to_have_css!("margin-left", "60px")
          end

          Locator.scroll_into_view_if_needed!(selector)
          expect_model_row_layout(selector)
        end
      end

      Page.set_viewport_size!(page, %{width: 1280, height: 900})

      if selection.id == "embedding" do
        Expect.to_be_disabled!(model)
        page |> Page.locator(~s|[phx-click="unlock_embedding"]|) |> Locator.click!()
        page |> Page.locator(~s|[phx-click="confirm_unlock_embedding"]|) |> Locator.click!()
        Expect.to_be_enabled!(model)
      end

      Locator.fill!(model, "private/updated-v2")
      Locator.press!(model, "Tab")
      wait_for_live_view_settled(page)
      form |> Locator.get_by_role(:button, name: ~r/^Save .* Settings$/) |> Locator.click!()

      if selection.id == "embedding" do
        page |> Page.locator(~s|[phx-click="confirm_save_embedding"]|) |> Locator.click!()
      end

      wait_for_live_view_settled(page)
      goto_back_office_live(page, "/bo/system-config?tab=#{selection.tab}")

      page
      |> Page.locator("##{selection.id}-model-input")
      |> Expect.to_have_value!("private/updated-v2")
    end
  end

  test "agent switches between catalog and custom selection without stale modalities", %{
    page: page,
    request: request
  } do
    custom =
      create_e2e_ai_credential(page, %{
        name: "Shared selector agent custom",
        provider: "Custom",
        endpoint: "http://localhost:11434/v1",
        api_key: "e2e-selector-key"
      })

    catalog = get_e2e_zaq_router_credential(request, with_api_key: true)

    agent =
      create_e2e_agent(request, %{
        name: "Shared selector agent",
        job: "Answer questions.",
        credential_id: custom["id"],
        model: "private/original"
      })

    goto_back_office_live(page, "/bo/agents")

    page
    |> Page.locator("#agent-row-#{agent["id"]}")
    |> Locator.get_by_text(agent["name"], exact: true)
    |> Locator.click!()

    selector = Page.locator(page, "#configured-agent-form .zaq-ai-model-selector")
    provider = Locator.locator(selector, ~s|select[name="configured_agent[credential_id]"]|)
    Locator.select_option!(provider, to_string(catalog["id"]))

    pick_searchable_select(
      page,
      "#configured-agent-model-select",
      "qwen/qwen3-vl-235b-a22b-instruct"
    )

    selector
    |> Locator.get_by_role(:button, name: "Input: Image", exact: true)
    |> Expect.to_be_visible!()

    Locator.select_option!(provider, to_string(custom["id"]))
    model = Page.locator(page, "#configured-agent-model-input")
    Expect.to_be_visible!(model)

    selector
    |> Locator.get_by_role(:button, name: "Input: Image", exact: true)
    |> Expect.to_have_count!(0)

    selector
    |> Locator.get_by_role(:button, name: "Input: Unknown", exact: true)
    |> Expect.to_be_visible!()

    Page.set_viewport_size!(page, %{width: 390, height: 844})
    Locator.scroll_into_view_if_needed!(selector)
    expect_model_row_layout(selector)
    Locator.fill!(model, "private/updated-agent")
    Locator.press!(model, "Tab")
    wait_for_live_view_settled(page)
    page |> Page.locator("#save-agent-button") |> Locator.click!()
    page |> Page.get_by_text("Agent updated", exact: true) |> Expect.to_be_visible!()
    goto_back_office_live(page, "/bo/agents")

    page
    |> Page.locator("#agent-row-#{agent["id"]}")
    |> Locator.get_by_text(agent["name"], exact: true)
    |> Locator.click!()

    page
    |> Page.locator("#configured-agent-model-input")
    |> Expect.to_have_value!("private/updated-agent")
  end
end
