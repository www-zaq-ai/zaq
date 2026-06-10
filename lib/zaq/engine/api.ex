defmodule Zaq.Engine.Api do
  @moduledoc """
  Engine role boundary module used by `Zaq.NodeRouter.dispatch/1`.
  """

  @behaviour Zaq.InternalBoundaries

  alias Zaq.Accounts.People
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.OAuth
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.PeopleGateway
  alias Zaq.Engine.Workflows
  alias Zaq.Event
  alias Zaq.InternalBoundaries
  alias Zaq.Permissions
  alias Zaq.System

  @impl true
  def handle_event(%Event{} = event, :persist_from_incoming, _context) do
    case event.request do
      %{incoming: %Incoming{} = incoming, metadata: metadata} when is_map(metadata) ->
        conversations_module = Keyword.get(event.opts, :conversations_module, Conversations)
        %{event | response: conversations_module.persist_from_incoming(incoming, metadata)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :noop, _context), do: event

  def handle_event(%Event{} = event, :invoke, _context),
    do: InternalBoundaries.invoke_request(event)

  def handle_event(%Event{} = event, :get_person, _context) do
    case event.request do
      %{person_id: person_id} ->
        people_module = Keyword.get(event.opts, :people_module, People)
        %{event | response: people_module.get_person(person_id)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :people_command, _context) do
    case event.request do
      %{op: op, params: params} when is_atom(op) and is_map(params) ->
        %{event | response: PeopleGateway.dispatch(op, params)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :connect_get_active_grant, _context) do
    case event.request do
      params when is_map(params) ->
        connect_module = Keyword.get(event.opts, :connect_module, Connect)
        %{event | response: connect_module.get_active_grant(params)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :connect_fetch_credential, _context) do
    case event.request do
      %{credential_id: credential_id} ->
        connect_module = Keyword.get(event.opts, :connect_module, Connect)
        %{event | response: connect_module.fetch_credential(credential_id)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :connect_list_credentials, _context),
    do: %{event | response: Connect.list_credentials()}

  def handle_event(%Event{} = event, :connect_change_credential, _context) do
    case event.request do
      %{credential: credential, attrs: attrs} when is_map(attrs) ->
        %{event | response: Connect.change_credential(credential, attrs)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :connect_create_credential, _context) do
    case event.request do
      %{attrs: attrs} when is_map(attrs) ->
        %{event | response: Connect.create_credential(attrs)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :connect_list_grants, _context) do
    case event.request do
      %{filters: filters} when is_map(filters) ->
        %{event | response: Connect.list_grants(Map.to_list(filters))}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :connect_issue_grant, _context) do
    case event.request do
      %{attrs: attrs} when is_map(attrs) ->
        %{event | response: Connect.issue_grant(attrs)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :connect_update_grant_token_cache, _context) do
    case event.request do
      %{grant: grant, token_payload: token_payload} when is_map(token_payload) ->
        %{event | response: Connect.update_grant_token_cache(grant, token_payload)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :system_config_list_ai_provider_credentials, _context) do
    %{event | response: System.list_ai_provider_credentials()}
  end

  def handle_event(%Event{} = event, :system_config_get_ai_provider_credential, _context) do
    case event.request do
      %{id: id} -> %{event | response: System.get_ai_provider_credential(id)}
      other -> %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :system_config_get_ai_provider_credential_bang, _context) do
    case event.request do
      %{id: id} ->
        case System.get_ai_provider_credential(id) do
          nil -> %{event | response: {:error, :not_found}}
          credential -> %{event | response: {:ok, credential}}
        end

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :system_config_change_ai_provider_credential, _context) do
    case event.request do
      %{credential: credential, attrs: attrs} when is_map(attrs) ->
        %{event | response: System.change_ai_provider_credential(credential, attrs)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :system_config_create_ai_provider_credential, _context) do
    case event.request do
      %{attrs: attrs} when is_map(attrs) ->
        %{event | response: System.create_ai_provider_credential(attrs)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :system_config_update_ai_provider_credential, _context) do
    case event.request do
      %{credential: credential, attrs: attrs} when is_map(attrs) ->
        %{event | response: System.update_ai_provider_credential(credential, attrs)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :system_config_delete_ai_provider_credential, _context) do
    case event.request do
      %{credential: credential} ->
        %{event | response: System.delete_ai_provider_credential(credential)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :system_config_get_telemetry_config, _context),
    do: %{event | response: System.get_telemetry_config()}

  def handle_event(%Event{} = event, :system_config_save_telemetry_config, _context) do
    case event.request do
      %{changeset: changeset} -> %{event | response: System.save_telemetry_config(changeset)}
      other -> %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :system_config_get_global_default_agent_id, _context),
    do: %{event | response: System.get_global_default_agent_id()}

  def handle_event(%Event{} = event, :system_config_set_global_default_agent_id, _context) do
    case event.request do
      %{id: id} -> %{event | response: System.set_global_default_agent_id(id)}
      other -> %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :system_config_get_global_base_url, _context),
    do: %{event | response: System.get_global_base_url()}

  def handle_event(%Event{} = event, :system_config_set_global_base_url, _context) do
    case event.request do
      %{base_url: base_url} -> %{event | response: System.set_global_base_url(base_url)}
      other -> %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :system_config_get_llm_config, _context),
    do: %{event | response: System.get_llm_config()}

  def handle_event(%Event{} = event, :system_config_save_llm_config, _context) do
    case event.request do
      %{changeset: changeset} -> %{event | response: System.save_llm_config(changeset)}
      other -> %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :system_config_get_embedding_config, _context),
    do: %{event | response: System.get_embedding_config()}

  def handle_event(%Event{} = event, :system_config_save_embedding_config, _context) do
    case event.request do
      %{changeset: changeset} -> %{event | response: System.save_embedding_config(changeset)}
      other -> %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :system_config_embedding_ready, _context),
    do: %{event | response: System.embedding_ready?()}

  def handle_event(%Event{} = event, :system_config_get_image_to_text_config, _context),
    do: %{event | response: System.get_image_to_text_config()}

  def handle_event(%Event{} = event, :system_config_save_image_to_text_config, _context) do
    case event.request do
      %{changeset: changeset} -> %{event | response: System.save_image_to_text_config(changeset)}
      other -> %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :system_config_connect_list_credentials, _context),
    do: %{event | response: Connect.list_credentials()}

  def handle_event(%Event{} = event, :system_config_connect_change_credential, context),
    do: handle_event(event, :connect_change_credential, context)

  def handle_event(%Event{} = event, :system_config_connect_update_credential, _context) do
    case event.request do
      %{credential: credential, attrs: attrs} when is_map(attrs) ->
        %{event | response: Connect.update_credential(credential, attrs)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :system_config_connect_list_grants, _context) do
    case event.request do
      %{credential_id: credential_id} ->
        %{event | response: Connect.list_grants(credential_id: credential_id)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(
        %Event{} = event,
        :system_config_connect_next_refresh_jobs_for_grants,
        _context
      ) do
    case event.request do
      %{grants: grants} when is_list(grants) ->
        %{event | response: Connect.next_refresh_jobs_for_grants(grants)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :system_config_connect_delete_grant, _context) do
    case event.request do
      %{grant: grant} -> %{event | response: Connect.delete_grant(grant)}
      other -> %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :system_config_connect_schedule_refresh, _context) do
    case event.request do
      %{grant: grant} -> %{event | response: Connect.schedule_refresh(grant)}
      other -> %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :connect_oauth_redirect_uri_for, _context) do
    case event.request do
      %{provider: provider} ->
        oauth_module = Keyword.get(event.opts, :connect_oauth_module, OAuth)
        %{event | response: oauth_module.redirect_uri_for(provider)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :connect_oauth_build_authorize_url, _context) do
    case event.request do
      %{credential: credential, context: context} when is_map(context) ->
        oauth_module = Keyword.get(event.opts, :connect_oauth_module, OAuth)
        %{event | response: oauth_module.build_authorize_url(credential, context)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :workflow, _context) do
    case event.request do
      %{action: "run.approve", run_id: run_id, person_id: person_id} = req ->
        decision = Map.get(req, :decision, %{})
        approved_by = to_string(person_id || "admin")

        %{
          event
          | response:
              handle_workflow_approve(run_id, person_id, decision, approved_by, event.opts)
        }

      %{action: "run.reject", run_id: run_id, person_id: person_id} = req ->
        reason = Map.get(req, :reason, "rejected")
        approved_by = to_string(person_id || "admin")

        %{
          event
          | response: handle_workflow_reject(run_id, person_id, reason, approved_by, event.opts)
        }

      %{action: action} when action in ["run.approve", "run.reject"] ->
        %{event | response: {:error, {:invalid_request, event.request}}}

      %{action: action, run_id: run_id}
      when action in [
             "run.started",
             "run.completed",
             "run.failed",
             "run.waiting",
             "run.cancelled"
           ] ->
        broadcast_run_update(run_id)
        event

      _other ->
        event
    end
  end

  @doc """
  Handles all trigger management operations from the BO.

  Sub-routes on `event.request.action`:
  - `"list_with_runs"` — list all triggers with workflows and recent runs
  - `"create"` `%{attrs: map}` — create trigger
  - `"update"` `%{trigger: t, attrs: map}` — update trigger
  - `"delete"` `%{trigger: t}` — delete trigger
  - `"assign_workflow"` `%{trigger: t, workflow: w}` — link workflow
  - `"remove_workflow"` `%{trigger: t, workflow: w}` — unlink workflow
  - `"list_workflows"` — list all workflows (for assignment picker)
  """
  def handle_event(%Event{} = event, :trigger, _context) do
    case event.request do
      %{action: "list_with_runs"} ->
        %{event | response: Workflows.list_triggers_with_workflows_and_recent_runs()}

      %{action: "create", attrs: attrs} when is_map(attrs) ->
        %{event | response: Workflows.create_trigger(attrs)}

      %{action: "update", trigger: trigger, attrs: attrs} when is_map(attrs) ->
        %{event | response: Workflows.update_trigger(trigger, attrs)}

      %{action: "delete", trigger: trigger} ->
        %{event | response: Workflows.delete_trigger(trigger)}

      %{action: "assign_workflow", trigger: trigger, workflow: workflow} ->
        %{event | response: Workflows.assign_workflow_to_trigger(trigger, workflow)}

      %{action: "remove_workflow", trigger: trigger, workflow: workflow} ->
        %{event | response: Workflows.remove_workflow_from_trigger(trigger, workflow)}

      %{action: "list_workflows"} ->
        %{event | response: Workflows.list_workflows()}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, action, _context) do
    %{event | response: {:error, {:unsupported_action, action}}}
  end

  defp handle_workflow_approve(run_id, person_id, decision, approved_by, opts) do
    with run when not is_nil(run) <- Workflows.get_run(run_id),
         true <- permission_granted?(person_id, run, opts),
         approval when not is_nil(approval) <- Workflows.get_pending_approval(run.id) do
      Workflows.approve_run(run, approval, decision, approved_by)
    else
      false -> {:error, :unauthorized}
      nil -> {:error, {:invalid_request, %{run_id: run_id}}}
    end
  end

  defp handle_workflow_reject(run_id, person_id, reason, approved_by, opts) do
    with run when not is_nil(run) <- Workflows.get_run(run_id),
         true <- permission_granted?(person_id, run, opts),
         approval when not is_nil(approval) <- Workflows.get_pending_approval(run.id) do
      Workflows.reject_run(run, approval, reason, approved_by)
    else
      false -> {:error, :unauthorized}
      nil -> {:error, {:invalid_request, %{run_id: run_id}}}
    end
  end

  defp permission_granted?(nil, _run, opts), do: Keyword.get(opts, :skip_permissions, false)

  defp permission_granted?(person_id, run, _opts) do
    workflow = Workflows.get_workflow!(run.workflow_id)
    person = People.get_person(person_id)
    person != nil and Permissions.can?(person, :run, workflow)
  end

  defp broadcast_run_update(run_id) do
    case Workflows.get_run(run_id) do
      %Zaq.Engine.Workflows.WorkflowRun{} = run ->
        Phoenix.PubSub.broadcast(Zaq.PubSub, "workflow_run:#{run_id}", {:run_updated, run})

      _ ->
        :ok
    end
  end
end
