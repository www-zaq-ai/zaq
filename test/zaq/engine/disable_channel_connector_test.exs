defmodule Zaq.Engine.DisableChannelConnectorTest do
  use Zaq.DataCase, async: true

  import Zaq.AccountsFixtures

  alias Zaq.Engine.Actions.DisableChannelConnector
  alias Zaq.Engine.ChannelConfig
  alias Zaq.{Event, Repo}

  defmodule ChannelsRouter do
    def dispatch(%Event{opts: opts, request: request} = event) do
      send(event.actor.observer, {:channels_command, opts[:action], request})

      response =
        case opts[:action] do
          :connector_logout -> Map.get(event.actor, :logout_result, :ok)
          :connector_sync_runtime -> Map.get(event.actor, :sync_result, :ok)
        end

      %{event | response: response}
    end
  end

  setup do
    user = super_admin_fixture(%{must_change_password: false})
    config = insert_config("whatsapp")

    context = %{
      actor: %{user_id: user.id, observer: self()},
      confidential: true,
      opts: [router: ChannelsRouter]
    }

    %{config: config, context: context}
  end

  test "confirmation context is scoped and secret-free", %{config: config, context: context} do
    assert {:ok, %{result: {:ok, descriptor}}} = run(:context, config, context)
    assert descriptor.channel_config_id == config.id
    assert is_binary(descriptor.revision)
    refute Map.has_key?(descriptor, :token)

    assert {:ok, %{result: {:error, :connector_not_found}}} =
             run(:context, %{config | provider: "telegram"}, context)

    refute_received {:channels_command, _, _}
  end

  test "logout precedes disabling and runtime sync; repeat confirmation is harmless", %{
    config: config,
    context: context
  } do
    assert {:ok, %{result: {:ok, descriptor}}} = run(:context, config, context)
    request = Map.put(descriptor, :op, :disable)

    assert {:ok, %{result: {:ok, %{status: :disabled, runtime: :synced}}}} =
             Jido.Exec.run(DisableChannelConnector, %{request: request}, context)

    assert_receive {:channels_command, :connector_logout, %{config: %{id: id, enabled: true}}}
    assert id == config.id

    assert_receive {:channels_command, :connector_sync_runtime,
                    %{after_config: %{id: ^id, enabled: false}}}

    refute Repo.get!(ChannelConfig, id).enabled

    assert {:ok, %{result: {:ok, %{status: :already_disabled}}}} =
             Jido.Exec.run(DisableChannelConnector, %{request: request}, context)

    refute_received {:channels_command, :connector_logout, _}
  end

  test "logout failure preserves enablement", %{config: config, context: context} do
    context = put_in(context.actor[:logout_result], {:error, :logout_failed})
    assert {:ok, %{result: {:ok, descriptor}}} = run(:context, config, context)

    assert {:ok, %{result: {:error, {:logout_failed, :logout_failed}}}} =
             Jido.Exec.run(
               DisableChannelConnector,
               %{request: Map.put(descriptor, :op, :disable)},
               context
             )

    assert Repo.get!(ChannelConfig, config.id).enabled
    refute_received {:channels_command, :connector_sync_runtime, _}
  end

  test "stale confirmation cannot log out an edited connector", %{
    config: config,
    context: context
  } do
    assert {:ok, %{result: {:ok, descriptor}}} = run(:context, config, context)
    config |> Ecto.Changeset.change(name: "Changed") |> Repo.update!()

    assert {:ok, %{result: {:error, :stale_connector}}} =
             Jido.Exec.run(
               DisableChannelConnector,
               %{request: Map.put(descriptor, :op, :disable)},
               context
             )

    assert Repo.get!(ChannelConfig, config.id).enabled
    refute_received {:channels_command, _, _}
  end

  test "runtime cleanup failure is reported after successful logout and persistence", %{
    config: config,
    context: context
  } do
    context = put_in(context.actor[:sync_result], {:error, :unavailable})
    assert {:ok, %{result: {:ok, descriptor}}} = run(:context, config, context)

    assert {:ok, %{result: {:ok, %{status: :disabled, runtime: {:pending, :unavailable}}}}} =
             Jido.Exec.run(
               DisableChannelConnector,
               %{request: Map.put(descriptor, :op, :disable)},
               context
             )

    refute Repo.get!(ChannelConfig, config.id).enabled
  end

  test "rejects missing, non-admin and non-confidential actors", %{
    config: config,
    context: context
  } do
    user = user_fixture()

    for rejected <- [
          %{context | actor: nil},
          %{context | actor: %{user_id: user.id}},
          %{context | confidential: false}
        ] do
      assert {:error, _} = run(:context, config, rejected)
    end

    assert Repo.get!(ChannelConfig, config.id).enabled
    refute_received {:channels_command, _, _}
  end

  defp run(op, config, context) do
    Jido.Exec.run(
      DisableChannelConnector,
      %{
        request: %{
          op: op,
          channel_config_id: config.id,
          provider: config.provider,
          kind: config.kind
        }
      },
      context
    )
  end

  defp insert_config(provider) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{name: "Account", provider: provider, kind: "retrieval"})
    |> Repo.insert!()
  end
end
