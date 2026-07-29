defmodule Zaq.Agent.Tools.General.ListProvidersTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.General.ListProviders
  alias Zaq.Channels.Api
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Workflows.Action
  alias Zaq.Event

  defmodule StubNodeRouter do
    @moduledoc false
    def dispatch(%Event{request: request, opts: opts}) do
      send(self(), {:dispatch, opts[:action], request})

      %{
        Event.new(%{}, :channels)
        | response: {:ok, %{providers: [%{provider: "disk", label: "Disk"}]}}
      }
    end
  end

  defmodule ErrorNodeRouter do
    @moduledoc false
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: {:error, :timeout}}
  end

  test "satisfies the workflow action contract" do
    assert :ok = Action.validate(ListProviders)
  end

  test "dispatches the provider listing action with the requested kind" do
    assert {:ok, %{providers: [%{provider: "disk", label: "Disk"}]}} =
             ListProviders.run(%{kind: "data_source"}, %{node_router: StubNodeRouter})

    assert_received {:dispatch, :channel_list_providers, %{kind: :data_source}}
  end

  test "dispatches the communication kind as an atom" do
    assert {:ok, _} = ListProviders.run(%{kind: "communication"}, %{node_router: StubNodeRouter})

    assert_received {:dispatch, :channel_list_providers, %{kind: :communication}}
  end

  test "rejects an unknown kind before dispatching" do
    assert {:error, _} = ListProviders.validate_params(%{kind: "nonsense"})
  end

  test "requires a kind" do
    assert {:error, _} = ListProviders.validate_params(%{})
  end

  test "formats datasource error reason" do
    assert {:error, message} =
             ListProviders.run(%{kind: "data_source"}, %{node_router: ErrorNodeRouter})

    assert message == "Channel provider listing failed: :timeout"
  end

  describe "through the real channels boundary" do
    defmodule LocalNodeRouter do
      @moduledoc false

      def dispatch(%Event{} = event),
        do: Api.handle_event(event, :channel_list_providers, nil)
    end

    test "data_source lists disk plus every writable data_source config with its status" do
      insert_config("google_drive", "data_source", true)
      insert_config("sharepoint", "data_source", false)
      insert_config("mattermost", "retrieval", true)

      assert {:ok, %{providers: providers}} =
               ListProviders.run(%{kind: "data_source"}, %{node_router: LocalNodeRouter})

      assert Enum.map(providers, & &1.provider) == ["disk", "google_drive", "sharepoint"]
      assert Enum.map(providers, & &1.label) == ["Disk", "Google Drive", "SharePoint"]
      assert Enum.map(providers, & &1.status) == [:active, :active, :inactive]
    end

    test "data_source lists disk alone when nothing is configured" do
      assert {:ok, %{providers: [%{provider: "disk"}]}} =
               ListProviders.run(%{kind: "data_source"}, %{node_router: LocalNodeRouter})
    end

    test "communication lists retrieval configs with a status, never disk" do
      insert_config("mattermost", "retrieval", true)
      insert_config("slack", "retrieval", false)
      insert_config("google_drive", "data_source", true)

      assert {:ok, %{providers: providers}} =
               ListProviders.run(%{kind: "communication"}, %{node_router: LocalNodeRouter})

      keys = Enum.map(providers, & &1.provider)

      refute "disk" in keys
      refute "google_drive" in keys
      # slack has no bridge wired, so it is not a place a message can go
      refute "slack" in keys
      assert Enum.all?(providers, &Map.has_key?(&1, :label))
      assert Enum.all?(providers, &(&1.status in [:active, :inactive]))
    end

    test "communication offers nothing active when no retrieval config is enabled" do
      assert {:ok, %{providers: providers}} =
               ListProviders.run(%{kind: "communication"}, %{node_router: LocalNodeRouter})

      # The seeded email:smtp config ships disabled, so it is listed but not usable.
      assert Enum.all?(providers, &(&1.status == :inactive))
    end

    test "an unknown kind is rejected at the channels boundary" do
      event = Event.new(%{kind: :nope}, :channels, opts: [action: :channel_list_providers])

      assert %{response: {:error, {:unknown_channel_kind, :nope}}} =
               Api.handle_event(event, :channel_list_providers, nil)
    end

    defp insert_config(provider, kind, enabled) do
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "#{provider} config",
        provider: provider,
        kind: kind,
        enabled: enabled,
        url: "https://example.test/#{provider}",
        token: "test-token"
      })
      |> Repo.insert!()
    end
  end
end
