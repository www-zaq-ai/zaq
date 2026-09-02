defmodule Zaq.Events.TrustedContextTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Event
  alias Zaq.Events.TrustedContext

  test "normalizes only transport-safe execution context" do
    actor = %{person_id: 7, provider: "bo"}

    context =
      TrustedContext.normalize(%{
        actor: actor,
        skip_permissions: true,
        credentials: %{token: "secret"},
        event_opts: [action: :attacker_selected],
        node_router: __MODULE__
      })

    assert context == %TrustedContext{actor: actor, skip_permissions: true}
    refute Map.has_key?(Map.from_struct(context), :credentials)
    refute Map.has_key?(Map.from_struct(context), :event_opts)
    refute Map.has_key?(Map.from_struct(context), :node_router)
  end

  test "normalizes an event without trusting request fields" do
    actor = %{person_id: 7}

    event =
      Event.new(%{"skip_permissions" => true, "actor" => %{person_id: 999}}, :channels,
        actor: actor,
        opts: [skip_permissions: true]
      )

    assert TrustedContext.from_event(event) ==
             %TrustedContext{actor: actor, skip_permissions: true}
  end

  test "from_event trusts a string-keyed actor permission bypass" do
    actor = %{"person_id" => 7, "skip_permissions" => true}
    event = Event.new(%{}, :channels, actor: actor)

    assert TrustedContext.from_event(event) ==
             %TrustedContext{actor: actor, skip_permissions: true}
  end

  property "only literal trusted true enables permission bypass" do
    check all(value <- StreamData.term() |> StreamData.filter(&(&1 != true))) do
      refute TrustedContext.normalize(%{skip_permissions: value}).skip_permissions
    end
  end

  test "builds event options without relaying arbitrary context event options" do
    opts =
      TrustedContext.event_builder_opts(
        %{
          actor: %{person_id: 7},
          skip_permissions: true,
          node_router: __MODULE__,
          event_opts: [action: :attacker_selected, data_source_bridge_module: __MODULE__]
        },
        event_opts: [materialization_verified: true]
      )

    assert opts[:actor] == %{person_id: 7}
    assert opts[:node_router] == __MODULE__
    assert opts[:event_opts][:skip_permissions] == true
    assert opts[:event_opts][:materialization_verified] == true
    assert opts[:event_opts][:data_source_bridge_module] == __MODULE__
    refute Keyword.has_key?(opts[:event_opts], :action)
  end

  property "non-list context event options are ignored" do
    check all(context_event_opts <- StreamData.term() |> StreamData.filter(&(not is_list(&1)))) do
      opts =
        TrustedContext.event_builder_opts(
          %{event_opts: context_event_opts},
          event_opts: [materialization_verified: true]
        )

      assert opts[:event_opts] == [materialization_verified: true]
      refute Keyword.has_key?(opts, :actor)
      refute Keyword.has_key?(opts, :node_router)
      refute Keyword.has_key?(opts, :config)
    end
  end
end
