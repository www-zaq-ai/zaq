defmodule ZaqWeb.Live.BO.System.OperationModelFormsTest do
  use ZaqWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  import Zaq.SystemConfigFixtures

  alias Zaq.Accounts
  alias Zaq.System
  alias ZaqWeb.Live.BO.System.SystemConfigLive

  @forms [
    {:small, "global", "operation_model_config", "validate_operation_model",
     "save_operation_model", "small", "Model settings saved."},
    {:translation, "rag", "operation_model_config", "validate_operation_model",
     "save_operation_model", "translation", "Model settings saved."},
    {:decision, "global", "decision_model_config", "validate_decision_model",
     "save_decision_model", "decision", "Decision model settings saved."},
    {:reranking, "rag", "rag_model_config", "validate_rag_model", "save_rag_model",
     "rag-reranking", "RAG model settings saved. Not active in the pipeline."}
  ]

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    stub(Zaq.NodeRouterMock, :dispatch, &Zaq.NodeRouter.dispatch/1)

    %{
      user: user,
      conn:
        init_test_session(conn, %{
          user_id: user.id,
          system_config_node_router_module: Zaq.NodeRouterMock
        })
    }
  end

  for {kind, tab, form_name, validate, save, prefix, message} <- @forms do
    test "#{kind} validates catalog switches, manual input and clears without queries or Engine reads",
         %{conn: conn, user: user} do
      kind = unquote(kind)
      form_name = unquote(form_name)
      prefix = unquote(prefix)
      custom = ai_credential_fixture(%{provider: "custom"})
      catalog = ai_credential_fixture(%{provider: "zaq_router", api_key: "model-form-test-key"})
      {:ok, view, _} = live(conn, "/bo/system-config?tab=#{unquote(tab)}")
      socket = validation_socket(user, unquote(tab))

      params = %{
        "kind" => to_string(kind),
        form_name => %{"credential_id" => to_string(catalog.id), "model" => "stale-model"}
      }

      socket = assert_local_validation(socket, unquote(validate), params)
      render_change(view, unquote(validate), params)
      assert_input_value(view, "##{prefix}-model-select input[data-select-value]", "")
      refute has_element?(view, "##{prefix}-model-input")

      params = put_in(params, [form_name, "credential_id"], to_string(custom.id))
      socket = assert_local_validation(socket, unquote(validate), params)
      render_change(view, unquote(validate), params)
      assert_input_value(view, "##{prefix}-model-input", "")
      refute has_element?(view, "##{prefix}-model-select")

      params = put_in(params, [form_name, "model"], "custom/#{kind}")
      socket = assert_local_validation(socket, unquote(validate), params)
      render_change(view, unquote(validate), params)
      assert has_element?(view, "##{prefix}-model-input[value='custom/#{kind}']")

      params = put_in(params, [form_name], %{"credential_id" => "", "model" => ""})
      assert_local_validation(socket, unquote(validate), params)
      render_change(view, unquote(validate), params)
      assert_input_value(view, "##{prefix}-credential-select input[data-select-value]", "")
      assert model_config(kind).model == nil
    end

    test "#{kind} keeps submitted input on dispatch failure and saves through its existing boundary",
         %{conn: conn} do
      kind = unquote(kind)
      form_name = unquote(form_name)
      prefix = unquote(prefix)
      credential = ai_credential_fixture(%{provider: "custom"})
      {:ok, view, _} = live(conn, "/bo/system-config?tab=#{unquote(tab)}")

      params = %{
        "kind" => to_string(kind),
        form_name => %{"credential_id" => to_string(credential.id), "model" => "custom/#{kind}"}
      }

      stub(Zaq.NodeRouterMock, :dispatch, fn event ->
        assert event.next_hop.destination == :engine
        assert event.opts[:action] == save_action(kind)
        assert event.request[:attrs] == params[form_name]
        assert event.request[:kind] == request_kind(kind)
        %{event | response: {:error, :unavailable}}
      end)

      html = render_submit(view, unquote(save), params)
      assert html =~ "Please retry."
      refute html =~ unquote(message)
      assert has_element?(view, "##{prefix}-model-input[value='custom/#{kind}']")
      assert model_config(kind).model == nil

      stub(Zaq.NodeRouterMock, :dispatch, &Zaq.NodeRouter.dispatch/1)
      assert render_submit(view, unquote(save), params) =~ unquote(message)
      assert model_config(kind).model == "custom/#{kind}"
    end
  end

  test "generation validation and saves preserve loaded non-default sampling", %{
    conn: conn,
    user: user
  } do
    credential = ai_credential_fixture(%{provider: "custom"})

    for {kind, tab} <- [small: "global", translation: "rag"] do
      assert {:ok, _} =
               System.save_operation_model_config(kind, %{
                 credential_id: credential.id,
                 model: "original",
                 temperature: 1.3,
                 top_p: 0.6
               })

      {:ok, view, _} = live(conn, "/bo/system-config?tab=#{tab}")
      socket = validation_socket(user, tab)

      params = %{
        "kind" => to_string(kind),
        "operation_model_config" => %{
          "credential_id" => to_string(credential.id),
          "model" => "updated"
        }
      }

      assert_local_validation(socket, "validate_operation_model", params)
      render_change(view, "validate_operation_model", params)
      assert render_submit(view, "save_operation_model", params) =~ "Model settings saved."
      assert %{model: "updated", temperature: 1.3, top_p: 0.6} = model_config(kind)
    end
  end

  test "a newly saved credential refreshes cached catalogs before selecting a model", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/bo/system-config?tab=ai_credentials")
    render_click(view, "new_ai_credential", %{})
    name = "New catalog #{Ecto.UUID.generate()}"

    assert render_submit(view, "save_ai_credential", %{
             "ai_credential" => %{
               "name" => name,
               "provider" => "zaq_router",
               "endpoint" => "http://localhost:11434/v1",
               "auth_kind" => "api_key",
               "api_key" => "model-form-test-key"
             }
           }) =~ "AI credential saved."

    credential = Enum.find(System.list_ai_provider_credentials(), &(&1.name == name))
    render_patch(view, ~p"/bo/system-config?tab=global")

    render_change(view, "validate_decision_model", %{
      "decision_model_config" => %{"credential_id" => to_string(credential.id), "model" => ""}
    })

    assert has_element?(view, "#decision-model-select li[data-select-value='typesafe/jev-1.14']")
    refute has_element?(view, "#decision-model-input")
  end

  defp validation_socket(user, tab) do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user: user}}

    {:ok, socket} =
      SystemConfigLive.mount(
        %{},
        %{"system_config_node_router_module" => Zaq.NodeRouterMock},
        socket
      )

    {:noreply, socket} = SystemConfigLive.handle_params(%{"tab" => tab}, "", socket)
    socket
  end

  defp assert_input_value(view, selector, expected) do
    value =
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input")
      |> LazyHTML.attribute("value")
      |> List.first()

    assert (value || "") == expected
  end

  defp assert_local_validation(socket, event, params) do
    parent = self()
    ref = make_ref()
    handler = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler,
        [:zaq, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == parent, do: send(parent, {ref, :query, metadata[:source]})
        end,
        nil
      )

    stub(Zaq.NodeRouterMock, :dispatch, fn event ->
      send(parent, {ref, :dispatch, event.opts[:action]})
      Zaq.NodeRouter.dispatch(event)
    end)

    try do
      {:noreply, socket} = SystemConfigLive.handle_event(event, params, socket)
      refute_received {^ref, :query, _}
      refute_received {^ref, :dispatch, _}
      socket
    after
      :telemetry.detach(handler)
      stub(Zaq.NodeRouterMock, :dispatch, &Zaq.NodeRouter.dispatch/1)
    end
  end

  defp model_config(kind) when kind in [:small, :translation],
    do: System.get_operation_model_config(kind)

  defp model_config(:decision), do: System.get_decision_model_config()
  defp model_config(:reranking), do: System.get_rag_model_config(:reranking)

  defp save_action(kind) when kind in [:small, :translation],
    do: :system_config_save_operation_model_config

  defp save_action(:decision), do: :system_config_save_decision_model_config
  defp save_action(:reranking), do: :system_config_save_rag_model_config

  defp request_kind(:decision), do: nil
  defp request_kind(kind), do: kind
end
