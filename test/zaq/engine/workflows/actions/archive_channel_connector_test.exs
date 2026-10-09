defmodule Zaq.Engine.Workflows.Actions.ArchiveChannelConnectorTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Zaq.AccountsFixtures

  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Workflows.Actions.ArchiveChannelConnector
  alias Zaq.Event

  defmodule Router do
    alias Zaq.Event

    def dispatch(%Event{} = event) do
      send(event.actor.test_pid, {:channels_event, event})

      response =
        case event.opts[:action] do
          :connector_teardown_ingress -> {:ok, :deleted}
          :connector_sync_runtime -> :ok
          action -> raise "unexpected Channels action: #{inspect(action)}"
        end

      %{event | response: response}
    end
  end

  defp insert_retrieval_config do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "archive-action-#{System.unique_integer([:positive])}",
      provider: "mattermost",
      kind: "retrieval",
      url: "http://localhost",
      token: "test-token",
      enabled: true,
      settings: %{}
    })
    |> Repo.insert!()
  end

  defp params(config),
    do: %{channel_config_id: config.id, provider: "mattermost", kind: "retrieval"}

  defp context(actor), do: %{actor: actor, opts: [router: Router]}

  test "archives an exactly scoped retrieval connector through the Action" do
    user = super_admin_fixture(%{must_change_password: false})
    config = insert_retrieval_config()
    actor = %{user_id: user.id, test_pid: self()}

    assert {:ok, %{result: result}} =
             Jido.Exec.run(ArchiveChannelConnector, params(config), context(actor))

    assert result.channel_config_id == config.id
    assert result.status == :archived
    assert result.ingress == :deleted
    assert result.runtime == :synced
    assert result.watch_teardown == %{status: :not_required, count: 0}
    assert result.cleanup == %{status: :not_required, count: 0}

    assert_received {:channels_event, %Event{} = ingress}
    assert ingress.opts[:action] == :connector_teardown_ingress
    assert ingress.opts[:confidential] == true
    assert ingress.actor == actor
    assert ingress.request.config.id == config.id
    assert_received {:channels_event, %Event{} = runtime}
    assert runtime.opts[:action] == :connector_sync_runtime
    assert runtime.opts[:confidential] == true
    assert runtime.actor == actor
    assert runtime.request.after_config.id == config.id

    archived = Repo.get!(ChannelConfig, config.id)
    assert archived.archived_at
    refute archived.enabled
  end

  test "propagates exact-scope domain failures without dispatching" do
    user = super_admin_fixture(%{must_change_password: false})
    config = insert_retrieval_config()
    actor_context = context(%{user_id: user.id})

    assert {:error, :connector_not_found} =
             ArchiveChannelConnector.run(
               %{params(config) | channel_config_id: config.id + 100_000},
               actor_context
             )

    assert {:error, :connector_not_found} =
             ArchiveChannelConnector.run(
               %{params(config) | provider: "slack"},
               actor_context
             )

    unchanged = Repo.get!(ChannelConfig, config.id)
    assert unchanged.enabled
    refute unchanged.archived_at
    refute_received {:channels_event, _}
  end

  property "invalid trusted identities cannot archive or dispatch" do
    config = insert_retrieval_config()
    original = Repo.get!(ChannelConfig, config.id)

    check all(actor <- member_of([nil, %{}, %{person_id: 123_456}, %{user_id: -1}])) do
      assert {:error, :unauthorized} =
               ArchiveChannelConnector.run(params(config), context(actor))

      assert Repo.get!(ChannelConfig, config.id) == original
      refute_received {:channels_event, _}
    end
  end

  test "an actor-looking Action input does not supply trusted identity" do
    config = insert_retrieval_config()

    assert {:error, :unauthorized} =
             ArchiveChannelConnector.run(
               Map.put(params(config), :actor, %{user_id: 1}),
               %{opts: [router: Router]}
             )

    assert Repo.get!(ChannelConfig, config.id).enabled
    refute_received {:channels_event, _}
  end

  test "rejects malformed params and context shapes before side effects" do
    user = super_admin_fixture(%{must_change_password: false})
    config = insert_retrieval_config()

    assert {:error, :unauthorized} =
             ArchiveChannelConnector.run(nil, %{actor: %{user_id: user.id}})

    assert {:error, :unauthorized} = ArchiveChannelConnector.run(params(config), nil)
    assert Repo.get!(ChannelConfig, config.id).enabled
    refute_received {:channels_event, _}
  end
end
