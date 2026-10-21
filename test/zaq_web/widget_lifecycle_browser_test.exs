defmodule ZaqWeb.WidgetLifecycleBrowserTest do
  use Zaq.DataCase, async: false

  @moduletag :real_browser

  alias Zaq.Accounts.People
  alias Zaq.Agent.ServerManager
  alias Zaq.Channels.WebBridge
  alias Zaq.ConnectorConfig.WidgetSettings
  alias Zaq.Contracts.ToolStep
  alias Zaq.Engine.{ChannelConfig, IncomingMessageRouting}

  alias Zaq.Engine.Conversations.{
    Conversation,
    ExecutionRecord,
    Message,
    Transcript,
    TranscriptMessage
  }

  alias Zaq.SystemConfigFixtures

  alias Zaq.TestSupport.{
    HistoryBrowser,
    MultiAgentOpenAIStub,
    OpenAIStub,
    ToolCallingLLMStub,
    WidgetBrowserParent
  }

  setup do
    isolate_event_registry()
    restore_dependencies()
    previous_roles = System.get_env("ROLES")
    System.put_env("ROLES", "all")
    previous_channels = Application.fetch_env!(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.put(previous_channels, :web_widget, %{bridge: WebBridge, adapter: WebWidget.HostAdapter})
    )

    replace_infrastructure(pubsub_server: Zaq.PubSub, session: [partitioned: false])

    on_exit(fn ->
      Application.put_env(:zaq, :channels, previous_channels)
      replace_infrastructure(pubsub_server: Zaq.PubSub)

      if previous_roles,
        do: System.put_env("ROLES", previous_roles),
        else: System.delete_env("ROLES")
    end)

    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")
    state = start_supervised!({Agent, fn -> %{} end})

    parent =
      start_supervised!(
        {Bandit, plug: {WidgetBrowserParent, state: state}, port: 0, ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(parent)
    %{parent_origin: "http://localhost:#{port}", parent_state: state}
  end

  for engine <- ~w(chromium firefox webkit), reconnect? <- [false, true] do
    @tag timeout: 180_000
    test "#{engine}: signed embedded widget executes real tools and restores canonical history (reconnect #{reconnect?})",
         ctx do
      owner = self()

      handler =
        ToolCallingLLMStub.handler(
          routes: [
            %{
              match: &String.contains?(&1, "add 2 and 3"),
              tool: "add",
              arguments: fn _ -> %{value: 2, amount: 3} end
            }
          ],
          final_response: fn %{tool_result: result} ->
            assert result == %{"ok" => true, "result" => %{"result" => 5.0}}
            "The real sum is 5."
          end
        )

      {spec, endpoint} =
        OpenAIStub.server(
          fn conn, body ->
            response = handler.(conn, body)

            if MultiAgentOpenAIStub.tool_results(Jason.decode!(body)) != [] do
              send(owner, {:model_waiting, self()})

              receive do
                :release_answer -> :ok
              after
                30_000 -> raise "Browser did not observe real tool activity"
              end
            end

            response
          end,
          owner
        )

      start_supervised!(spec)
      OpenAIStub.seed_llm_config(endpoint, model: "gpt-4.1-mini")
      configured = configured_agent(endpoint)
      widget = widget(ctx, configured)

      HistoryBrowser.run!(
        %{
          runner: "test/e2e/support/widget-lifecycle-browser.cjs",
          engine: unquote(engine),
          reconnect: unquote(reconnect?),
          parent_origin: ctx.parent_origin,
          widget_id: widget.id
        },
        fn
          "tools-visible", state ->
            assert_receive {:llm_tool_call, "add", %{"value" => 2, "amount" => 3}}, 15_000

            assert_receive {:llm_tool_result, "add",
                            %{"ok" => true, "result" => %{"result" => 5.0}}},
                           15_000

            assert_receive {:model_waiting, worker}, 15_000
            on_exit(fn -> send(worker, :release_answer) end)

            if unquote(reconnect?) do
              pending =
                Repo.one!(from e in widget_executions(widget.id), where: e.status == "pending")

              input = Repo.get!(Message, pending.user_message_id)
              {%{conversation_id: input.conversation_id}, Map.put(state, :worker, worker)}
            else
              send(worker, :release_answer)
              {%{}, state}
            end

          "resumed", state ->
            send(state.worker, :release_answer)
            {%{}, state}

          "saved", state ->
            answer =
              Repo.one!(
                from m in widget_messages(widget.id), where: m.content == "The real sum is 5."
              )

            execution =
              Repo.one!(
                from e in ExecutionRecord, where: e.public_answer_message_id == ^answer.id
              )

            assert execution.status == "completed"
            steps = ToolStep.from_trace(execution.trace_entries)
            assert [%{"name" => "add", "state" => "succeeded"}] = steps
            assert execution.reserved_answer_message_id == answer.id

            {%{answer_id: answer.id, conversation_id: answer.conversation_id, steps: steps},
             state}
        end
      )

      refute_received {:llm_stub_error, _}
      :ok = ServerManager.stop_server(configured)
    end
  end

  for engine <- ~w(chromium firefox webkit),
      scenario <- [:provider_failure, :cancel, :crash],
      partial? <- [false, true] do
    @tag timeout: 120_000
    @tag widget_scenario: scenario, partial_text?: partial?, browser_engine: engine
    test "#{engine}: real widget #{scenario} with partial text #{partial?}", ctx do
      scenario = ctx.widget_scenario
      partial? = ctx.partial_text?
      owner = self()

      handler =
        ToolCallingLLMStub.handler(
          routes: [
            %{
              match: &String.contains?(&1, "add 2 and 3"),
              tool: "add",
              arguments: fn _ -> %{value: 2, amount: 3} end
            }
          ],
          final_response: "This result must never be delivered."
        )

      {spec, endpoint} =
        OpenAIStub.server(
          fn conn, body ->
            response = handler.(conn, body)

            if MultiAgentOpenAIStub.tool_results(Jason.decode!(body)) == [] do
              response
            else
              conn =
                conn
                |> Plug.Conn.put_resp_content_type("text/event-stream")
                |> Plug.Conn.send_chunked(200)

              conn =
                if partial? do
                  [delta, _] =
                    String.split(
                      MultiAgentOpenAIStub.text_sse(
                        "Partial answer already shown.",
                        "gpt-4.1-mini"
                      ),
                      "event: response.completed"
                    )

                  {:ok, conn} = Plug.Conn.chunk(conn, delta)
                  conn
                else
                  conn
                end

              send(owner, {:interruptible_model, self()})

              receive do
                :finish_provider ->
                  terminal =
                    if scenario == :provider_failure do
                      "event: response.failed\ndata: " <>
                        Jason.encode!(%{
                          response: %{
                            error: %{code: "server_error", message: "Fixture interruption"}
                          }
                        }) <> "\n\n"
                    else
                      MultiAgentOpenAIStub.text_sse(
                        "This result must never be delivered.",
                        "gpt-4.1-mini"
                      )
                    end

                  result = Plug.Conn.chunk(conn, terminal)
                  send(owner, {:provider_finished, scenario})

                  case result do
                    {:ok, conn} -> conn
                    {:error, :closed} -> conn
                  end
              after
                30_000 -> raise "Browser did not release interrupted provider"
              end
            end
          end,
          owner
        )

      start_supervised!(spec)
      OpenAIStub.seed_llm_config(endpoint, model: "gpt-4.1-mini")
      configured = configured_agent(endpoint)
      widget = widget(ctx, configured)

      HistoryBrowser.run!(
        %{
          runner: "test/e2e/support/widget-lifecycle-browser.cjs",
          engine: ctx.browser_engine,
          scenario: "interruption",
          partial: partial?,
          parent_origin: ctx.parent_origin,
          widget_id: widget.id
        },
        fn
          "interrupt", state ->
            assert_receive {:llm_tool_result, "add",
                            %{"ok" => true, "result" => %{"result" => 5.0}}},
                           15_000

            assert_receive {:interruptible_model, model}, 15_000
            on_exit(fn -> send(model, :finish_provider) end)

            pending =
              Repo.one!(from e in widget_executions(widget.id), where: e.status == "pending")

            {:ok, [target]} =
              ServerManager.runtime_candidates(%{person: %{id: pending.person_id}})

            case scenario do
              :provider_failure ->
                :ok

              :cancel ->
                signal =
                  Jido.Signal.new!("ai.react.cancel", %{reason: :user_cancelled},
                    source: "/ai/react/agent"
                  )

                :ok = Jido.AgentServer.cast(target.runtime_pid, signal)

              :crash ->
                {:ok, status} = Jido.AgentServer.status(target.runtime_pid)
                worker = status.raw_state.__strategy__.react_worker_pid
                ref = Process.monitor(worker)
                Process.exit(worker, :kill)
                assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 5_000
            end

            if scenario == :provider_failure, do: send(model, :finish_provider)
            {%{}, Map.merge(state, %{execution_id: pending.id, model: model})}

          "settled", state ->
            execution = Repo.get!(ExecutionRecord, state.execution_id)
            assert execution.status == "failed"
            assert is_nil(execution.public_answer_message_id)

            if scenario == :cancel do
              assert execution.outcome["termination_reason"] == "cancelled"
            end

            if scenario == :crash do
              assert execution.outcome["reason"] == ":agent_execution_failed"
            end

            assert [%{"name" => "add", "state" => "succeeded"}] =
                     ToolStep.from_trace(execution.trace_entries)

            if scenario != :provider_failure, do: send(state.model, :finish_provider)
            assert_receive {:provider_finished, ^scenario}, 5_000
            {%{}, state}
        end
      )

      refute_received {:llm_stub_error, _}
    end
  end

  test "real widgets isolate simultaneous requests across connectors", ctx do
    owner = self()

    widgets =
      for {value, amount} <- [{2, 3}, {7, 4}] do
        answer = "Verified sum #{value + amount}."
        prompt = "Please add #{value} and #{amount}"

        handler =
          ToolCallingLLMStub.handler(
            routes: [
              %{
                match: &String.contains?(&1, prompt),
                tool: "add",
                arguments: fn _ -> %{value: value, amount: amount} end
              }
            ],
            final_response: fn %{tool_result: result} ->
              assert result == %{"ok" => true, "result" => %{"result" => (value + amount) / 1}}
              answer
            end
          )

        {spec, endpoint} =
          OpenAIStub.server(
            fn conn, body ->
              result = handler.(conn, body)

              if MultiAgentOpenAIStub.tool_results(Jason.decode!(body)) != [] do
                send(owner, {:isolated_wait, prompt, self()})

                receive do
                  :release_answer -> :ok
                after
                  30_000 -> raise "Isolation browser did not release response"
                end
              end

              result
            end,
            owner
          )

        start_supervised!(Supervisor.child_spec(spec, id: make_ref()))
        OpenAIStub.seed_llm_config(endpoint, model: "gpt-4.1-mini")
        configured = configured_agent(endpoint)
        config = widget(ctx, configured)
        %{widget_id: config.id, prompt: prompt, answer: answer}
      end

    HistoryBrowser.run!(
      %{
        runner: "test/e2e/support/widget-lifecycle-browser.cjs",
        engine: "chromium",
        scenario: "isolation",
        parent_origin: ctx.parent_origin,
        widgets: widgets
      },
      fn
        "concurrent", state ->
          workers =
            for _ <- 1..2 do
              assert_receive {:isolated_wait, prompt, worker}, 15_000
              on_exit(fn -> send(worker, :release_answer) end)
              {prompt, worker}
            end

          assert Enum.sort(Enum.map(workers, &elem(&1, 0))) ==
                   Enum.sort(Enum.map(widgets, & &1.prompt))

          ids = Enum.map(widgets, & &1.widget_id)

          assert Repo.aggregate(
                   from(e in widget_executions(ids), where: e.status == "pending"),
                   :count
                 ) ==
                   2

          workers
          |> Enum.reverse()
          |> Enum.each(fn {_, worker} -> send(worker, :release_answer) end)

          {%{}, state}

        "isolated-saved", state ->
          answers =
            for widget <- widgets do
              answer =
                Repo.one!(
                  from m in widget_messages(widget.widget_id), where: m.content == ^widget.answer
                )

              execution =
                Repo.one!(
                  from e in ExecutionRecord, where: e.public_answer_message_id == ^answer.id
                )

              assert execution.status == "completed"
              input = Repo.get!(Message, execution.user_message_id)

              assert Repo.get!(Conversation, input.conversation_id).channel_config_id ==
                       widget.widget_id

              %{conversation_id: answer.conversation_id, answer_id: answer.id}
            end

          assert answers |> Enum.map(& &1.answer_id) |> Enum.uniq() |> length() == 2
          {%{answers: answers}, state}
      end
    )

    refute_received {:llm_stub_error, _}
  end

  test "NONE routing acknowledges input without an assistant or model execution", ctx do
    widget = widget(ctx, nil)

    HistoryBrowser.run!(
      %{
        runner: "test/e2e/support/widget-lifecycle-browser.cjs",
        engine: "chromium",
        scenario: "no-answer",
        parent_origin: ctx.parent_origin,
        widget_id: widget.id
      },
      fn "no-answer", state ->
        input = Repo.one!(widget_messages(widget.id))
        assert input.source_provider == "web_widget"
        assert input.role == "external"
        assert Repo.aggregate(widget_executions(widget.id), :count) == 0
        refute_received {:openai_request, _, _, _, _}
        {%{}, state}
      end
    )
  end

  test "inactive sender is rejected before Agent execution and retains the draft", ctx do
    widget = widget(ctx, nil)

    HistoryBrowser.run!(
      %{
        runner: "test/e2e/support/widget-lifecycle-browser.cjs",
        engine: "chromium",
        scenario: "rejection",
        parent_origin: ctx.parent_origin,
        widget_id: widget.id
      },
      fn
        "revoke-sender", state ->
          {:ok, person} =
            People.match_by_channel("web_widget", "widget-browser-person", widget.id)

          {:ok, _} = People.update_person(person, %{status: "inactive"})
          {%{}, state}

        "rejected", state ->
          assert Repo.aggregate(widget_executions(widget.id), :count) == 0
          assert Repo.aggregate(widget_messages(widget.id), :count) == 0
          refute_received {:openai_request, _, _, _, _}
          {%{}, state}
      end
    )
  end

  defp configured_agent(endpoint) do
    credential =
      SystemConfigFixtures.ai_credential_fixture(%{
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, configured} =
      Zaq.Agent.create_agent(%{
        name: "Widget browser #{Ecto.UUID.generate()}",
        job: "Use the arithmetic tool and answer briefly.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: ["arithmetic.add"],
        conversation_enabled: true,
        active: true,
        model_max_context_tokens: 128_000,
        advanced_options: %{"stream" => true}
      })

    on_exit(fn -> ServerManager.stop_server(configured) end)
    configured
  end

  defp widget_messages(config_id) do
    from m in Message,
      join: placement in TranscriptMessage,
      on: placement.message_id == m.id,
      join: transcript in Transcript,
      on: transcript.id == placement.transcript_id,
      where: transcript.channel_config_id == ^config_id,
      distinct: true
  end

  defp widget_executions(config_ids) do
    ids = List.wrap(config_ids)

    from e in ExecutionRecord,
      join: placement in TranscriptMessage,
      on: placement.message_id == e.user_message_id,
      join: transcript in Transcript,
      on: transcript.id == placement.transcript_id,
      where: transcript.channel_config_id in ^ids,
      distinct: true
  end

  defp widget(ctx, configured) do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Browser widget #{Ecto.UUID.generate()}",
        provider: "web_widget",
        kind: "retrieval",
        enabled: true,
        token: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
        settings:
          WidgetSettings.defaults()
          |> Map.merge(%{"same_site" => "Lax", "allowed_domains" => [ctx.parent_origin]})
      })
      |> Repo.insert!()

    rule =
      if configured,
        do: %{routing_mode: :agent, configured_agent_id: configured.id},
        else: %{routing_mode: :none}

    {:ok, _} = IncomingMessageRouting.upsert_rule(%{channel_config_id: config.id}, rule)

    runtime =
      config
      |> ChannelConfig.to_runtime_config()
      |> Map.take([:id, :name, :provider, :enabled, :token, :settings])

    assert :ok = WebBridge.start_runtime(runtime)
    Agent.update(ctx.parent_state, &Map.put(&1, to_string(config.id), runtime))
    on_exit(fn -> WebBridge.stop_runtime(runtime) end)
    config
  end

  defp restore_dependencies do
    keys = [:node_router, :pipeline_executor_module, :pipeline_hooks_module]
    previous = Map.new(keys, &{&1, Application.fetch_env(:zaq, &1)})
    Enum.each(keys, &Application.delete_env(:zaq, &1))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:zaq, key, value)
        {key, :error} -> Application.delete_env(:zaq, key)
      end)
    end)
  end

  defp replace_infrastructure(opts) do
    if pid = Process.whereis(WebWidget.Supervisor),
      do: DynamicSupervisor.terminate_child(Zaq.Channels.BridgeSupervisor, pid)

    {:ok, [spec]} =
      WebWidget.HostAdapter.infrastructure_child_specs(Keyword.put(opts, :scope, "/channels"))

    {:ok, _} = DynamicSupervisor.start_child(Zaq.Channels.BridgeSupervisor, spec)
  end
end
