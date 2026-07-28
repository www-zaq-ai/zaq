defmodule Zaq.Agent.Tools.DataSource.ListProvidersTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.DataSource.ListProviders
  alias Zaq.Channels.ChannelConfig
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

  test "dispatches the provider listing action with an empty request" do
    assert {:ok, %{providers: [%{provider: "disk", label: "Disk"}]}} =
             ListProviders.run(%{}, %{node_router: StubNodeRouter})

    assert_received {:dispatch, :data_source_list_providers, %{}}
  end

  test "formats datasource error reason" do
    assert {:error, message} = ListProviders.run(%{}, %{node_router: ErrorNodeRouter})

    assert message == "Data source provider listing failed: :timeout"
  end

  describe "through the real channels boundary" do
    defmodule LocalNodeRouter do
      @moduledoc false
      alias Zaq.Channels.Api

      def dispatch(%Event{} = event),
        do: Api.handle_event(event, :data_source_list_providers, nil)
    end

    test "lists disk plus every enabled, writable data_source config" do
      insert_config("google_drive", "data_source", true)
      insert_config("sharepoint", "data_source", false)
      insert_config("mattermost", "retrieval", true)

      assert {:ok, %{providers: providers}} =
               ListProviders.run(%{}, %{node_router: LocalNodeRouter})

      assert Enum.map(providers, & &1.provider) == ["disk", "google_drive"]
      assert Enum.map(providers, & &1.label) == ["Disk", "Google Drive"]
    end

    test "lists disk alone when nothing is configured" do
      assert {:ok, %{providers: [%{provider: "disk"}]}} =
               ListProviders.run(%{}, %{node_router: LocalNodeRouter})
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
