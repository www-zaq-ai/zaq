defmodule Zaq.Engine.Messages.SourceIdentityTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Messages.Incoming.RoutingContext
  alias Zaq.Engine.Messages.SourceIdentity

  property "transport namespaces round-trip without collapsing distinct mailbox names" do
    check all(scope <- string(:alphanumeric, min_length: 1, max_length: 40)) do
      for value <- [scope, " " <> scope, scope <> " "] do
        context = RoutingContext.normalize(%{source_scope: value})
        assert context.source_scope == value

        assert Jason.decode!(SourceIdentity.account_key("provider", 12, context.source_scope)) ==
                 ["provider", 12, value]
      end
    end
  end

  test "malformed scopes stay invalid instead of becoming the connector-global namespace" do
    for scope <- ["", 12, %{}, String.duplicate("a", 256)] do
      assert RoutingContext.normalize(%{source_scope: scope}).source_scope == :invalid
    end

    assert RoutingContext.normalize(%{}).source_scope == nil
  end
end
