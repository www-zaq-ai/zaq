defmodule Zaq.Engine.ConnectorEnablementTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Zaq.AccountsFixtures
  alias Zaq.Engine.{Api, ChannelConfig, ConnectorLifecycle}
  alias Zaq.Event
  alias ZaqWeb.Live.BO.AI.BOActor

  defmodule Router do
    def dispatch(event) do
      ExUnit.Assertions.refute(Zaq.Repo.in_transaction?())
      config = Zaq.Repo.get!(ChannelConfig, event.request.after_config.id)
      after_config = event.request.after_config

      if event.request.phase == :before_persist and after_config.enabled do
        %{
          event
          | response: confirmed(after_config, {:pending, :configuration_required}, :after_persist)
        }
      else
        send(self(), {:runtime_sync, event.opts[:action], config.enabled})

        response =
          case Process.get(:runtime_response, :ok) do
            :ok ->
              confirmed(after_config, :complete, :none)

            {:pending, reason} ->
              confirmed(after_config, {:pending, reason}, :none)

            other ->
              other
          end

        %{event | response: response}
      end
    end

    defp confirmed(config, runtime, continuation),
      do:
        {:ok,
         %{
           transition: :confirmed,
           target: Map.take(config, [:id, :provider, :kind, :enabled]),
           runtime: runtime,
           continuation: continuation
         }}
  end

  setup do
    actor =
      super_admin_fixture(%{must_change_password: false})
      |> Repo.preload(:role)
      |> BOActor.build()

    config =
      Repo.insert!(%ChannelConfig{
        provider: "whatsapp",
        kind: "retrieval",
        name: "paired",
        url: "",
        token: "",
        enabled: false,
        settings: %{}
      })

    %{actor: actor, config: config}
  end

  test "existing lifecycle route persists enablement before runtime sync", context do
    assert {:ok, %{enabled: true, runtime: :ok}} = command(context, true)
    assert_received {:runtime_sync, :connector_sync_runtime, true}
    assert Repo.get!(ChannelConfig, context.config.id).enabled
  end

  test "runtime failure retains persisted state and reports the failure", context do
    Process.put(:runtime_response, {:error, :offline})
    assert {:ok, %{enabled: true, runtime: {:error, :unavailable}}} = command(context, true)
    assert Repo.get!(ChannelConfig, context.config.id).enabled
  end

  test "disable only persists when Channels confirms preparation and the desired scope",
       context do
    config = context.config |> Ecto.Changeset.change(enabled: true) |> Repo.update!()
    context = %{context | config: config}

    target = Map.take(%{config | enabled: false}, [:id, :provider, :kind, :enabled])

    for {response, reason} <- [
          {{:error, :failed}, :failed},
          {{:error, :unavailable}, :unavailable},
          {{:error, :channels_unavailable}, :unavailable},
          {:unexpected, :invalid_response},
          {{:ok,
            %{
              transition: :confirmed,
              target: %{target | id: config.id + 1},
              runtime: :complete,
              continuation: :none
            }}, :invalid_response},
          {{:ok,
            %{
              transition: :confirmed,
              target: target,
              runtime: :complete,
              continuation: :after_persist
            }}, :invalid_response}
        ] do
      Process.put(:runtime_response, response)
      assert {:error, ^reason} = command(context, false)
      assert_received {:runtime_sync, :connector_sync_runtime, true}
      assert Repo.get!(ChannelConfig, config.id).enabled
      refute Repo.get!(ChannelConfig, config.id).archived_at
    end

    Process.put(:runtime_response, {:pending, :unavailable})
    assert {:ok, %{enabled: false, runtime: {:error, :unavailable}}} = command(context, false)
    refute Repo.get!(ChannelConfig, config.id).enabled
  end

  test "Engine requires session authorization for restricted enablement", context do
    actor = %{user_id: staff_fixture(%{must_change_password: false}).id}
    assert {:error, :unauthorized} = command(%{context | actor: actor}, true)
    refute Repo.get!(ChannelConfig, context.config.id).enabled
    refute_received {:runtime_sync, _, _}
  end

  test "enablement consumes session authorization without a fresh user check", context do
    Zaq.Accounts.get_user!(context.actor.user_id)
    |> Ecto.Changeset.change(must_change_password: true)
    |> Repo.update!()

    {_, queries} =
      Zaq.QueryRecorder.capture(fn ->
        assert {:ok, %{enabled: true}} = command(context, true)
      end)

    refute Enum.any?(queries, &String.contains?(&1.query, "FROM \"users\""))
  end

  test "stale revision is rejected before runtime effects", context do
    event = event(context, true)
    context.config |> Ecto.Changeset.change(name: "changed") |> Repo.update!()

    assert %{response: {:error, :stale_connector}} =
             Api.handle_event(event, :connector_lifecycle, nil)

    refute_received {:runtime_sync, _, _}
  end

  test "confidentiality and runtime capability remain required", context do
    for opts <- [[], [confidential: true], [connector_lifecycle: true]] do
      event = %{event(context, true) | opts: opts}

      assert %{response: {:error, :unauthorized}} =
               Api.handle_event(event, :connector_lifecycle, nil)
    end

    refute Repo.get!(ChannelConfig, context.config.id).enabled
  end

  property "nonboolean desired states never mutate a connector", context do
    check all(invalid <- one_of([integer(), binary(), constant(nil)])) do
      assert {:error, :invalid_request} = command(context, invalid)
      refute Repo.get!(ChannelConfig, context.config.id).enabled
    end
  end

  defp command(context, enabled),
    do: Api.handle_event(event(context, enabled), :connector_lifecycle, nil).response

  defp event(%{config: config, actor: actor}, enabled) do
    {:ok, descriptor} = ConnectorLifecycle.context(config.id, config.provider, config.kind)

    Event.new(
      %{operation: :set_enabled, request: Map.put(descriptor, :enabled, enabled)},
      :engine,
      actor: actor,
      opts: [
        confidential: true,
        connector_lifecycle: true,
        router: Router,
        skip_permissions: actor[:skip_permissions] == true
      ]
    )
  end
end
