defmodule Zaq.Engine.ApiTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Api
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event

  defmodule StubConversations do
    def persist_from_incoming(incoming, metadata) do
      send(self(), {:persist_called, incoming, metadata})
      :ok
    end
  end

  defmodule StubConnect do
    def get_active_grant(params), do: {:grant, params}
    def fetch_credential(credential_id), do: {:ok, %{id: credential_id}}
  end

  defmodule StubOAuth do
    def redirect_uri_for(provider), do: "https://example.test/oauth/#{provider}/callback"
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

  test "delegates invoke to shared helper" do
    event = Event.new(%{module: String, function: :upcase, args: ["hi"]}, :engine)
    result = Api.handle_event(event, :invoke, nil)

    assert result.response == "HI"
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

  test "returns invalid request for malformed connect payloads" do
    assert Api.handle_event(Event.new("bad", :engine), :connect_get_active_grant, nil).response ==
             {:error, {:invalid_request, "bad"}}

    assert Api.handle_event(Event.new(%{}, :engine), :connect_fetch_credential, nil).response ==
             {:error, {:invalid_request, %{}}}

    assert Api.handle_event(Event.new(%{}, :engine), :connect_oauth_redirect_uri_for, nil).response ==
             {:error, {:invalid_request, %{}}}
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
      {:system_config_connect_schedule_refresh, %{}}
    ]

    Enum.each(invalid_cases, fn {action, request} ->
      result = Api.handle_event(Event.new(request, :engine), action, nil)
      assert result.response == {:error, {:invalid_request, request}}
    end)
  end
end
