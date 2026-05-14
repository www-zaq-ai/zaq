defmodule Zaq.Engine.Api do
  @moduledoc """
  Engine role boundary module used by `Zaq.NodeRouter.dispatch/1`.
  """

  @behaviour Zaq.InternalBoundaries

  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.OAuth
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.InternalBoundaries
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

  def handle_event(%Event{} = event, :invoke, _context),
    do: InternalBoundaries.invoke_request(event)

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

  def handle_event(%Event{} = event, :system_config_connect_change_credential, _context) do
    case event.request do
      %{credential: credential, attrs: attrs} when is_map(attrs) ->
        %{event | response: Connect.change_credential(credential, attrs)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

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

  def handle_event(%Event{} = event, action, _context) do
    %{event | response: {:error, {:unsupported_action, action}}}
  end
end
