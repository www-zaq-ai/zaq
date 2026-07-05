defmodule Zaq.Engine.ApiTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Api
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Workflows
  alias Zaq.Event

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  defmodule StubConversations do
    def persist_from_incoming(incoming, metadata) do
      send(self(), {:persist_called, incoming, metadata})
      :ok
    end

    def persist_message_history(incoming, message) do
      send(self(), {:persist_message_history_called, incoming, message})
      {:ok, %{conversation_id: "conversation-1", message_id: "message-1"}}
    end
  end

  defmodule StubConnect do
    def get_active_grant(params), do: {:grant, params}
    def fetch_credential(credential_id), do: {:ok, %{id: credential_id}}
  end

  defmodule StubOAuth do
    def redirect_uri_for(provider), do: "https://example.test/oauth/#{provider}/callback"
  end

  defmodule StubNotifications do
    def notify_person(person_id, attrs) do
      send(self(), {:notify_person_called, person_id, attrs})
      {:ok, %{status: :sent, channel: "email:smtp", channel_identifier: "person@example.com"}}
    end
  end

  test "handles persist_from_incoming action" do
    incoming = %Incoming{content: "hi", channel_id: "c1", provider: :web}
    metadata = %{answer: "ok"}

    event =
      Event.new(%{incoming: incoming, metadata: metadata}, :engine,
        opts: [action: :persist_from_incoming, conversations_module: StubConversations]
      )

    result = Api.handle_event(event, :persist_from_incoming, nil)

    assert result.response == :ok
    assert_received {:persist_called, ^incoming, ^metadata}
  end

  test "returns invalid request for malformed persist payload" do
    event =
      Event.new(%{incoming: :bad, metadata: %{}}, :engine, opts: [action: :persist_from_incoming])

    result = Api.handle_event(event, :persist_from_incoming, nil)

    assert result.response == {:error, {:invalid_request, %{incoming: :bad, metadata: %{}}}}
  end

  test "handles persist_message_history action" do
    incoming = %Incoming{content: "route", channel_id: "c1", provider: :mattermost}
    message = %{content: "Follow up", role: "assistant"}

    event =
      Event.new(%{incoming: incoming, message: message}, :engine,
        opts: [action: :persist_message_history, conversations_module: StubConversations]
      )

    result = Api.handle_event(event, :persist_message_history, nil)

    assert result.response == {:ok, %{conversation_id: "conversation-1", message_id: "message-1"}}
    assert_received {:persist_message_history_called, ^incoming, ^message}
  end

  test "returns invalid request for malformed persist_message_history payload" do
    event =
      Event.new(%{incoming: :bad, message: %{}}, :engine,
        opts: [action: :persist_message_history]
      )

    result = Api.handle_event(event, :persist_message_history, nil)

    assert result.response == {:error, {:invalid_request, %{incoming: :bad, message: %{}}}}
  end

  test "handles people_command action" do
    event =
      Event.new(%{op: :list_teams, params: %{}}, :engine, opts: [action: :people_command])

    result = Api.handle_event(event, :people_command, nil)

    assert match?({:ok, _}, result.response)
  end

  test "returns invalid request for malformed people_command payload" do
    event = Event.new(%{op: "bad", params: %{}}, :engine, opts: [action: :people_command])
    result = Api.handle_event(event, :people_command, nil)

    assert result.response == {:error, {:invalid_request, %{op: "bad", params: %{}}}}
  end

  test "handles notify_person action" do
    event =
      Event.new(
        %{person_id: 123, subject: "Hello", message: "Body"},
        :engine,
        opts: [action: :notify_person, notifications_module: StubNotifications]
      )

    result = Api.handle_event(event, :notify_person, nil)

    assert result.response ==
             {:ok,
              %{status: :sent, channel: "email:smtp", channel_identifier: "person@example.com"}}

    assert_received {:notify_person_called, 123, %{subject: "Hello", message: "Body"}}
  end

  test "returns invalid request for malformed notify_person payload" do
    event = Event.new(%{person_id: 123, subject: "Hello"}, :engine)
    result = Api.handle_event(event, :notify_person, nil)

    assert result.response ==
             {:error, {:invalid_request, %{person_id: 123, subject: "Hello"}}}
  end

  test "delegates invoke to shared helper" do
    event = Event.new(%{module: String, function: :upcase, args: ["hi"]}, :engine)
    result = Api.handle_event(event, :invoke, nil)

    assert result.response == "HI"
  end

  test "handles noop action by returning event unchanged" do
    event = Event.new(%{marker: 1}, :engine, opts: [action: :noop])

    result = Api.handle_event(event, :noop, nil)

    assert result == event
    assert result.request == %{marker: 1}
    assert result.response == event.response
  end

  test "returns unsupported action" do
    event = Event.new(%{}, :engine)
    result = Api.handle_event(event, :unknown, nil)

    assert result.response == {:error, {:unsupported_action, :unknown}}
  end

  test "handles connect_get_active_grant action" do
    params = %{provider: "google_drive", resource_type: "data_source", resource_id: 1}
    event = Event.new(params, :engine, opts: [connect_module: StubConnect])

    result = Api.handle_event(event, :connect_get_active_grant, nil)

    assert result.response == {:grant, params}
  end

  test "handles connect_fetch_credential action" do
    event = Event.new(%{credential_id: 42}, :engine, opts: [connect_module: StubConnect])

    result = Api.handle_event(event, :connect_fetch_credential, nil)

    assert result.response == {:ok, %{id: 42}}
  end

  test "handles connect_oauth_redirect_uri_for action" do
    event =
      Event.new(%{provider: "google_drive"}, :engine, opts: [connect_oauth_module: StubOAuth])

    result = Api.handle_event(event, :connect_oauth_redirect_uri_for, nil)

    assert result.response == "https://example.test/oauth/google_drive/callback"
  end

  test "returns invalid request for get_person with no person_id" do
    result = Api.handle_event(Event.new(%{}, :engine), :get_person, nil)
    assert result.response == {:error, {:invalid_request, %{}}}
  end

  test "returns invalid request for connect_create_credential with non-map attrs" do
    result = Api.handle_event(Event.new(%{attrs: :bad}, :engine), :connect_create_credential, nil)
    assert result.response == {:error, {:invalid_request, %{attrs: :bad}}}
  end

  test "handles connect_issue_grant with valid attrs map" do
    unique = System.unique_integer([:positive])

    {:ok, credential} =
      Connect.create_credential(%{
        name: "Api Test #{unique}",
        provider: "google_drive",
        auth_kind: "api_key",
        request_format: "raw",
        user_level: false,
        metadata: %{},
        api_key: "shared-token"
      })

    attrs = %{
      credential_id: credential.id,
      resource_type: "data_source",
      resource_id: "42",
      owner_type: "org",
      metadata: %{}
    }

    event = Event.new(%{attrs: attrs}, :engine)

    result = Api.handle_event(event, :connect_issue_grant, nil)

    assert {:ok, grant} = result.response
    assert grant.credential_id == credential.id
    assert grant.provider == "google_drive"
  end

  test "returns invalid request for connect_issue_grant when attrs is not map" do
    request = %{attrs: :bad}
    event = Event.new(request, :engine)

    result = Api.handle_event(event, :connect_issue_grant, nil)

    assert result.response == {:error, {:invalid_request, request}}
  end

  test "handles connect_update_grant_token_cache with valid grant and token_payload map" do
    unique = System.unique_integer([:positive])

    {:ok, credential} =
      Connect.create_credential(%{
        name: "JWT Test #{unique}",
        provider: "google_drive",
        auth_kind: "jwt_bearer",
        request_format: "bearer",
        user_level: false,
        metadata: %{"auth_profile_id" => "service_account"},
        issuer: "svc@example.iam.gserviceaccount.com",
        private_key: "private-key",
        key_id: "kid-1",
        scopes: ["https://www.googleapis.com/auth/drive.readonly"]
      })

    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        resource_type: "data_source",
        resource_id: "42",
        owner_type: "org",
        owner_id: nil,
        metadata: %{"auth_profile_id" => "service_account"},
        scopes: credential.scopes
      })

    token_payload = %{
      access_token: "new-token",
      expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }

    event = Event.new(%{grant: grant, token_payload: token_payload}, :engine)

    result = Api.handle_event(event, :connect_update_grant_token_cache, nil)

    assert {:ok, updated_grant} = result.response
    assert updated_grant.id == grant.id
    assert updated_grant.access_token == "new-token"
  end

  test "returns invalid request for connect_update_grant_token_cache when token_payload is not map" do
    request = %{grant: %{}, token_payload: :bad}
    event = Event.new(request, :engine)

    result = Api.handle_event(event, :connect_update_grant_token_cache, nil)

    assert result.response == {:error, {:invalid_request, request}}
  end

  test "returns invalid request for connect_list_grants with non-map filters" do
    result = Api.handle_event(Event.new(%{filters: :bad}, :engine), :connect_list_grants, nil)
    assert result.response == {:error, {:invalid_request, %{filters: :bad}}}
  end

  test "returns invalid request for connect_oauth_build_authorize_url with non-map context" do
    result =
      Api.handle_event(
        Event.new(%{credential: %{}, context: :bad}, :engine),
        :connect_oauth_build_authorize_url,
        nil
      )

    assert result.response == {:error, {:invalid_request, %{credential: %{}, context: :bad}}}
  end

  test "returns not_found for system_config_get_ai_provider_credential_bang with unknown id" do
    result =
      Api.handle_event(
        Event.new(%{id: 0}, :engine),
        :system_config_get_ai_provider_credential_bang,
        nil
      )

    assert result.response == {:error, :not_found}
  end

  test "returns invalid request for malformed connect payloads" do
    assert Api.handle_event(Event.new("bad", :engine), :connect_get_active_grant, nil).response ==
             {:error, {:invalid_request, "bad"}}

    assert Api.handle_event(Event.new(%{}, :engine), :connect_fetch_credential, nil).response ==
             {:error, {:invalid_request, %{}}}

    assert Api.handle_event(Event.new(%{}, :engine), :connect_oauth_redirect_uri_for, nil).response ==
             {:error, {:invalid_request, %{}}}
  end

  describe "handle_event/3 — :workflow events" do
    alias Zaq.Accounts.People
    alias Zaq.Engine.Workflows.WorkflowRunAgent
    alias Zaq.Permissions

    @source_event %{
      "request" => nil,
      "assigns" => %{"trigger_type" => "manual"},
      "trace_id" => "api-test-trace"
    }
    @ok_module "Zaq.Engine.Workflows.Test.OkAction"
    @hitl_module "Zaq.Engine.Workflows.Steps.HumanInTheLoop"

    defp api_hitl_workflow do
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "api-hitl-#{System.unique_integer()}",
          status: "active",
          nodes: [
            %{name: "step_a", type: "action", module: @ok_module, params: %{}, index: 0},
            %{name: "hitl", type: "action", module: @hitl_module, params: %{}, index: 1}
          ],
          edges: [%{from: "step_a", to: "hitl"}]
        })

      wf
    end

    defp create_waiting_run do
      wf = api_hitl_workflow()
      {:ok, run} = Workflows.create_run(wf, @source_event)
      {:ok, waiting_run} = WorkflowRunAgent.execute(run)
      assert waiting_run.status == "waiting"
      approval = Workflows.get_pending_approval(waiting_run.id)
      %{run: waiting_run, wf: wf, approval: approval}
    end

    test "run.approve with nil person_id and skip_permissions succeeds" do
      %{run: run} = create_waiting_run()

      request = %{
        action: "run.approve",
        run_id: run.id,
        person_id: nil,
        decision: %{"notes" => "looks good"}
      }

      result =
        Api.handle_event(
          Event.new(request, :engine, opts: [skip_permissions: true]),
          :workflow,
          nil
        )

      assert {:ok, completed_run} = result.response
      assert completed_run.status == "completed"
    end

    test "run.approve with nil person_id and no skip_permissions returns unauthorized" do
      %{run: run} = create_waiting_run()

      request = %{action: "run.approve", run_id: run.id, person_id: nil, decision: %{}}
      result = Api.handle_event(Event.new(request, :engine), :workflow, nil)
      assert result.response == {:error, :unauthorized}
    end

    test "run.approve with unknown person_id returns unauthorized" do
      %{run: run} = create_waiting_run()

      request = %{action: "run.approve", run_id: run.id, person_id: -1, decision: %{}}
      result = Api.handle_event(Event.new(request, :engine), :workflow, nil)
      assert result.response == {:error, :unauthorized}
    end

    test "run.approve with authorized person_id succeeds" do
      %{run: run, wf: wf} = create_waiting_run()
      unique = System.unique_integer([:positive])

      {:ok, person} =
        People.create_person(%{
          full_name: "Approver #{unique}",
          email: "approver#{unique}@test.com"
        })

      {:ok, _} = Permissions.grant(wf, %{person_id: person.id, access_rights: ["run"]})

      request = %{
        action: "run.approve",
        run_id: run.id,
        person_id: person.id,
        decision: %{"notes" => "approved by person"}
      }

      result = Api.handle_event(Event.new(request, :engine), :workflow, nil)
      assert {:ok, completed_run} = result.response
      assert completed_run.status == "completed"
    end

    test "run.reject with nil person_id and skip_permissions returns failed run" do
      %{run: run} = create_waiting_run()

      request = %{
        action: "run.reject",
        run_id: run.id,
        person_id: nil,
        reason: "not approved"
      }

      result =
        Api.handle_event(
          Event.new(request, :engine, opts: [skip_permissions: true]),
          :workflow,
          nil
        )

      assert {:ok, failed_run} = result.response
      assert failed_run.status == "failed"
    end

    test "run.reject with nil person_id and no skip_permissions returns unauthorized" do
      %{run: run} = create_waiting_run()

      request = %{action: "run.reject", run_id: run.id, person_id: nil, reason: "denied"}
      result = Api.handle_event(Event.new(request, :engine), :workflow, nil)
      assert result.response == {:error, :unauthorized}
    end

    test "run.reject with unknown person_id returns unauthorized" do
      %{run: run} = create_waiting_run()

      request = %{action: "run.reject", run_id: run.id, person_id: -1, reason: "denied"}
      result = Api.handle_event(Event.new(request, :engine), :workflow, nil)
      assert result.response == {:error, :unauthorized}
    end

    test "run.reject with authorized person_id returns failed run" do
      %{run: run, wf: wf} = create_waiting_run()
      unique = System.unique_integer([:positive])

      {:ok, person} =
        People.create_person(%{
          full_name: "Rejecter #{unique}",
          email: "rejecter#{unique}@test.com"
        })

      {:ok, _} = Permissions.grant(wf, %{person_id: person.id, access_rights: ["run"]})

      request = %{
        action: "run.reject",
        run_id: run.id,
        person_id: person.id,
        reason: "rejected by person"
      }

      result = Api.handle_event(Event.new(request, :engine), :workflow, nil)
      assert {:ok, failed_run} = result.response
      assert failed_run.status == "failed"
    end

    test "unknown action passes through event unchanged" do
      request = %{action: "unknown.action", run_id: "whatever"}
      event = Event.new(request, :engine)
      result = Api.handle_event(event, :workflow, nil)
      assert result.response == nil
    end

    test "missing run_id returns invalid_request" do
      request = %{action: "run.approve", person_id: nil}
      result = Api.handle_event(Event.new(request, :engine), :workflow, nil)
      assert {:error, {:invalid_request, _}} = result.response
    end
  end

  test "returns invalid request for system config actions requiring maps" do
    invalid_cases = [
      {:system_config_get_ai_provider_credential, %{}},
      {:system_config_get_ai_provider_credential_bang, %{}},
      {:system_config_change_ai_provider_credential, %{credential: %{id: 1}, attrs: :bad}},
      {:system_config_create_ai_provider_credential, %{attrs: :bad}},
      {:system_config_update_ai_provider_credential, %{credential: %{id: 1}, attrs: :bad}},
      {:system_config_delete_ai_provider_credential, %{}},
      {:system_config_save_telemetry_config, %{}},
      {:system_config_set_global_default_agent_id, %{}},
      {:system_config_save_llm_config, %{}},
      {:system_config_save_embedding_config, %{}},
      {:system_config_save_image_to_text_config, %{}},
      {:system_config_connect_change_credential, %{credential: %{id: 1}, attrs: :bad}},
      {:system_config_connect_update_credential, %{credential: %{id: 1}, attrs: :bad}},
      {:system_config_connect_list_grants, %{}},
      {:system_config_connect_next_refresh_jobs_for_grants, %{grants: :bad}},
      {:system_config_connect_delete_grant, %{}},
      {:system_config_connect_schedule_refresh, %{}},
      {:system_config_set_global_base_url, %{}}
    ]

    Enum.each(invalid_cases, fn {action, request} ->
      result = Api.handle_event(Event.new(request, :engine), action, nil)
      assert result.response == {:error, {:invalid_request, request}}
    end)
  end

  # --- :trigger handler ---

  @valid_node %{
    name: "step",
    type: "action",
    module: "Zaq.Engine.Workflows.Test.InboxWithResults",
    params: %{},
    index: 0
  }

  defp make_workflow(name \\ "W", status \\ "draft") do
    {:ok, w} =
      Workflows.create_workflow(%{name: name, status: status, nodes: [@valid_node], edges: []})

    w
  end

  defp make_trigger(event_name \\ "test.event") do
    {:ok, t} = Workflows.create_trigger(%{event_name: event_name})
    t
  end

  describe "handle_event/3 :trigger" do
    test "list_with_runs returns all triggers" do
      make_trigger("evt.a")
      make_trigger("evt.b")
      event = Event.new(%{action: "list_with_runs"}, :engine)
      result = Api.handle_event(event, :trigger, nil)
      assert is_list(result.response)
      assert length(result.response) == 2
    end

    test "create with valid attrs returns {:ok, trigger}" do
      event = Event.new(%{action: "create", attrs: %{event_name: "new.event"}}, :engine)
      result = Api.handle_event(event, :trigger, nil)
      assert {:ok, trigger} = result.response
      assert trigger.event_name == "engine:new.event"
    end

    test "create with invalid attrs returns changeset error" do
      event = Event.new(%{action: "create", attrs: %{event_name: ""}}, :engine)
      result = Api.handle_event(event, :trigger, nil)
      assert {:error, %Ecto.Changeset{}} = result.response
    end

    test "create missing attrs key returns invalid_request" do
      event = Event.new(%{action: "create"}, :engine)
      result = Api.handle_event(event, :trigger, nil)
      assert {:error, {:invalid_request, _}} = result.response
    end

    test "update with valid attrs returns {:ok, updated}" do
      t = make_trigger("evt.upd")
      event = Event.new(%{action: "update", trigger: t, attrs: %{enabled: false}}, :engine)
      result = Api.handle_event(event, :trigger, nil)
      assert {:ok, updated} = result.response
      assert updated.enabled == false
    end

    test "update missing attrs key returns invalid_request" do
      t = make_trigger()
      event = Event.new(%{action: "update", trigger: t}, :engine)
      result = Api.handle_event(event, :trigger, nil)
      assert {:error, {:invalid_request, _}} = result.response
    end

    test "delete removes trigger" do
      t = make_trigger("evt.del")
      event = Event.new(%{action: "delete", trigger: t}, :engine)
      result = Api.handle_event(event, :trigger, nil)
      assert {:ok, _} = result.response
      assert Workflows.list_triggers() |> Enum.all?(&(&1.id != t.id))
    end

    test "assign_workflow links workflow to trigger" do
      t = make_trigger()
      w = make_workflow("W", "active")
      event = Event.new(%{action: "assign_workflow", trigger: t, workflow: w}, :engine)
      result = Api.handle_event(event, :trigger, nil)
      assert {:ok, _} = result.response
      linked = Workflows.list_workflows_for_trigger(t.event_name)
      assert Enum.any?(linked, &(&1.id == w.id))
    end

    test "remove_workflow unlinks workflow from trigger" do
      t = make_trigger()
      w = make_workflow()
      Workflows.assign_workflow_to_trigger(t, w)
      event = Event.new(%{action: "remove_workflow", trigger: t, workflow: w}, :engine)
      result = Api.handle_event(event, :trigger, nil)
      assert {:ok, _} = result.response
    end

    test "list_workflows returns all workflows" do
      make_workflow("WA")
      make_workflow("WB")
      event = Event.new(%{action: "list_workflows"}, :engine)
      result = Api.handle_event(event, :trigger, nil)
      assert is_list(result.response)
      assert length(result.response) >= 2
    end

    test "unknown action string returns invalid_request" do
      event = Event.new(%{action: "unknown_action"}, :engine)
      result = Api.handle_event(event, :trigger, nil)
      assert {:error, {:invalid_request, _}} = result.response
    end
  end
end
