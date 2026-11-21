defmodule Zaq.E2EPw.WebbridgeChatTest do
  use Zaq.E2EPw.Case

  import Zaq.E2EPw.BO

  # Shared WebBridge BO chat

  # `let agent` of the spec: shared by the module's tests, created by the first one that runs.
  setup_all %{browser: browser} do
    request = APIRequest.new_context!(Playwright.request(BrowserPool.playwright(browser)))

    try do
      reset_e2e_state(request)
    after
      APIRequestContext.dispose!(request)
    end

    {:ok, agent_store} = Agent.start(fn -> nil end)
    on_exit(fn -> Agent.stop(agent_store) end)
    %{agent_store: agent_store}
  end

  setup %{page: page, agent_store: store} do
    login_to_back_office(page, return_to: "/bo/chat")

    {agent, created?} =
      Agent.get_and_update(store, fn
        nil ->
          agent = create_e2e_answering_agent(page)
          {{agent, true}, agent}

        agent ->
          {{agent, false}, agent}
      end)

    # The first test to run reloads after creating the agent.
    if created? do
      Page.reload!(page)
      wait_for_live_view_settled(page)
    end

    %{agent: agent}
  end

  defp start_new_chat(page, agent) do
    page |> Page.locator("#new-chat-button") |> Locator.click!()
    wait_for_live_view_settled(page)
    page |> Page.locator("#chat-messages") |> Expect.to_contain_text!("Welcome to ZAQ Chat!")
    page |> Page.locator(~s|[data-testid="chat-assistant-bubble"]|) |> Expect.to_have_count!(1)
    select_e2e_chat_agent(page, agent)
  end

  defp ask(page, question) do
    page |> Page.locator("#chat-input") |> Locator.fill!(question)
    page |> Page.locator("#chat-form button[type='submit']") |> Locator.click!()
    page |> Page.locator("#chat-messages") |> Expect.to_contain_text!(question)
    page |> Page.locator(~s|[data-testid="chat-assistant-bubble"]|) |> Expect.to_have_count!(2)

    page
    |> Page.locator(~s|[data-testid="source-chip"]|)
    |> Locator.first()
    |> Expect.to_be_visible!()

    wait_for_live_view_settled(page)
  end

  test "send, resume, citations, message information and new chat preserve BO behavior", %{
    page: page,
    agent: agent
  } do
    login_to_back_office(page, return_to: "/bo/chat")
    start_new_chat(page, agent)
    question = "WebBridge resume #{System.system_time(:millisecond)}"
    ask(page, question)

    answer = page |> Page.locator(~s|[data-testid="chat-assistant-bubble"]|) |> Locator.last()
    answer_text = Locator.inner_text!(answer)
    page |> Page.get_by_role(:button, name: "Show message information") |> Locator.click!()
    page |> Page.get_by_text("Message information", exact: true) |> Expect.to_be_visible!()
    page |> Page.get_by_text("Model", exact: true) |> Expect.to_be_visible!()
    page |> Page.get_by_text("openai:e2e-fake", exact: true) |> Expect.to_be_visible!()
    page |> Page.get_by_role(:button, name: "Close", exact: true) |> Locator.click!()

    start_new_chat(page, agent)
    page |> Page.locator("#chat-messages") |> Expect.not_() |> Expect.to_contain_text!(question)

    page
    |> Page.locator(~s|button[phx-click="load_conversation"]|)
    |> Locator.first()
    |> Locator.click!()

    wait_for_live_view_settled(page)
    page |> Page.locator("#chat-messages") |> Expect.to_contain_text!(question)
    page |> Page.locator(~s|[data-testid="chat-assistant-bubble"]|) |> Expect.to_have_count!(2)

    page
    |> Page.locator(~s|[data-testid="chat-assistant-bubble"]|)
    |> Locator.last()
    |> Expect.to_contain_text!(answer_text)
  end

  test "two live sessions receive only their own request results", %{
    page: page,
    context: context,
    agent: agent
  } do
    other = BrowserContext.new_page!(context)
    login_to_back_office(page, return_to: "/bo/chat")
    login_to_back_office(other, return_to: "/bo/chat")
    start_new_chat(page, agent)
    start_new_chat(other, agent)

    question = "WebBridge isolated #{System.system_time(:millisecond)}"
    ask(page, question)
    other |> Page.locator("#chat-messages") |> Expect.not_() |> Expect.to_contain_text!(question)
    other |> Page.locator(~s|[data-testid="chat-assistant-bubble"]|) |> Expect.to_have_count!(1)

    other_question = "WebBridge second session #{System.system_time(:millisecond)}"
    ask(other, other_question)

    page
    |> Page.locator("#chat-messages")
    |> Expect.not_()
    |> Expect.to_contain_text!(other_question)

    page |> Page.locator(~s|[data-testid="chat-assistant-bubble"]|) |> Expect.to_have_count!(2)
    Page.close!(other)
  end

  test "configured decision tool returns typed answers and alternative probabilities through real BO chat",
       %{page: page} do
    decision_credential =
      create_e2e_ai_credential(page, %{
        name: "E2E Decision #{System.system_time(:millisecond)}",
        provider: "zaq_router",
        endpoint: "http://127.0.0.1:4002/e2e/llm/v1",
        api_key: "decision-e2e-key"
      })

    # createE2EAiCredential returns the API's JSON; the select lists it by name.
    goto_back_office_live(page, "/bo/system-config?tab=global")
    pick_searchable_select(page, "#decision-credential-select", decision_credential["name"])
    pick_searchable_select(page, "#decision-model-select", "typesafe/jev-1.14")

    page
    |> Page.locator("#decision-model-form")
    |> Locator.get_by_role(:button, name: "Save Decision Model Settings")
    |> Locator.click!()

    page |> Page.get_by_text("Decision model settings saved.") |> Expect.to_be_visible!()

    chat_credential =
      create_e2e_ai_credential(page, %{
        name: "E2E Decision Chat #{System.system_time(:millisecond)}",
        provider: "custom",
        endpoint: "http://127.0.0.1:4002/e2e/llm/v1",
        api_key: "e2e-fake-key"
      })

    classifier =
      create_e2e_agent(Page.request(page), %{
        name: "E2E Classifier #{System.system_time(:millisecond)}",
        job: "E2E_DECISION_FLOW: use the decision tool and report its actual result.",
        credential_id: chat_credential["id"],
        model: "e2e-fake",
        model_max_context_tokens: 128_000,
        enabled_tool_keys: ["general.evaluate_decisions"],
        conversation_enabled: true,
        active: true,
        advanced_options: %{stream: true}
      })

    goto_back_office_live(page, "/bo/chat")
    start_new_chat(page, classifier)
    page |> Page.locator("#chat-input") |> Locator.fill!("Please classify a duplicate invoice")
    page |> Page.locator("#chat-form button[type=submit]") |> Locator.click!()
    answer = page |> Page.locator(~s|[data-testid="chat-assistant-bubble"]|) |> Locator.last()
    Expect.to_contain_text!(answer, "Decision result:")

    result = answer |> Locator.locator("pre code") |> Locator.inner_text!() |> JSON.decode!()

    assert result == %{
             "team" => %{
               "type" => "choice",
               "value" => "billing",
               "confidence" => nil,
               "probabilities" => %{"billing" => 0.9, "support" => 0.1}
             },
             "refund" => %{
               "type" => "boolean",
               "value" => true,
               "probability" => 0.8,
               "threshold" => 0.5
             },
             "urgency" => %{
               "type" => "score",
               "value" => 0.25,
               "confidence" => nil,
               "probabilities" => %{"0" => 0.75, "1" => 0.25}
             }
           }

    page
    |> Page.get_by_role(:list, name: "Tool activity")
    |> Expect.to_contain_text!(~r/evaluate[_ ]decisions/i)
  end

  test "new chat ignores a late result while the previous conversation still completes", %{
    page: page,
    context: context,
    agent: agent
  } do
    login_to_back_office(page, return_to: "/bo/chat")
    start_new_chat(page, agent)
    question = "E2E_DELAYED_WEBBRIDGE #{System.system_time(:millisecond)}"
    page |> Page.locator("#chat-input") |> Locator.fill!(question)
    history = BrowserContext.new_page!(context)
    base = normalize_base_url()
    api = Page.request(page)

    release = fn ->
      APIRequestContext.post!(api, base <> "/e2e/llm/release", data: %{token: question})
    end

    conversation_id =
      try do
        page |> Page.locator("#chat-form button[type='submit']") |> Locator.click!()

        Expect.poll!(
          fn ->
            response =
              APIRequestContext.get!(api, base <> "/e2e/llm/pending", params: %{token: question})

            assert APIResponse.ok(response)
            APIResponse.json!(response)["pending"]
          end,
          &assert(&1 == true)
        )

        page |> Page.locator("#chat-messages") |> Expect.to_contain_text!(question)
        page |> Page.locator(~s|[data-testid="source-chip"]|) |> Expect.to_have_count!(0)
        start_new_chat(page, agent)
        # The sending view refreshes its sidebar on completion. A fresh view can already see the
        # persisted pending conversation; verify its unique question.
        login_to_back_office(history, return_to: "/bo/chat")

        pending_conversation =
          history |> Page.locator(~s|button[phx-click="load_conversation"]|) |> Locator.first()

        conversation_id = Locator.get_attribute!(pending_conversation, "phx-value-id")
        Locator.click!(pending_conversation)
        history |> Page.locator("#chat-messages") |> Expect.to_contain_text!(question)
        released = release.()
        assert APIResponse.ok(released)
        conversation_id
      after
        # Also release on assertion failure; the fixture has a bounded timeout as a backstop.
        release.()
      end

    # Observe actual finalization from another LiveView, rather than sleeping and allowing a
    # negative assertion to pass before the late result arrives.
    Expect.to_pass!(
      fn ->
        Page.reload!(history)
        wait_for_live_view_settled(history)

        history
        |> Page.locator(
          ~s|button[phx-click="load_conversation"][phx-value-id="#{conversation_id}"]|
        )
        |> Locator.click!()

        history |> Page.locator("#chat-messages") |> Expect.to_contain_text!(question)

        history
        |> Page.locator(~s|[data-testid="source-chip"]|)
        |> Locator.first()
        |> Expect.to_be_visible!(timeout: 1_000)
      end,
      timeout: 20_000
    )

    wait_for_live_view_settled(page)
    page |> Page.locator("#chat-messages") |> Expect.not_() |> Expect.to_contain_text!(question)
    page |> Page.locator(~s|[data-testid="source-chip"]|) |> Expect.to_have_count!(0)
    page |> Page.locator(~s|[data-testid="chat-assistant-bubble"]|) |> Expect.to_have_count!(1)
    page |> Page.locator("#chat-messages") |> Expect.to_contain_text!("Welcome to ZAQ Chat!")
    Page.close!(history)
  end
end
