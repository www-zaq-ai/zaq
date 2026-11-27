defmodule Zaq.Events.ActorClearanceContextTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Event
  alias Zaq.Events.TrustedContext

  test "only explicit runtime context and event options transport caller clearance escape" do
    actor = %{kind: :bo_user, subject: "12", user_id: 12}
    context = TrustedContext.normalize(%{actor: actor, skip_actor_clearance: true})
    assert context.skip_actor_clearance
    refute context.skip_permissions

    opts = TrustedContext.event_builder_opts(context)
    assert opts[:event_opts][:skip_actor_clearance] == true

    assert TrustedContext.from_event(
             Event.new(%{}, :engine, actor: actor, opts: opts[:event_opts])
           ) ==
             context
  end

  test "request and actor fields cannot enable clearance escape" do
    event =
      Event.new(%{skip_actor_clearance: true}, :engine,
        actor: %{user_id: 12, skip_actor_clearance: true, skip_permissions: true}
      )

    refute TrustedContext.from_event(event).skip_actor_clearance
  end

  property "only literal true in trusted context enables the narrow escape" do
    check all(value <- term() |> filter(&(&1 != true))) do
      refute TrustedContext.normalize(%{skip_actor_clearance: value}).skip_actor_clearance
    end
  end
end
