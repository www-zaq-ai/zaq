defmodule Zaq.NodeRolesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.NodeRoles

  test "all/0 returns every concrete node role in order" do
    assert NodeRoles.all() == [:bo, :agent, :ingestion, :storage, :channels, :engine]
  end

  test "parse/1 recognizes the all role after trimming" do
    assert NodeRoles.parse(" all ") == [:all]
  end

  test "parse/1 raises for unknown roles" do
    assert_raise ArgumentError, ~s(unknown ZAQ node role: "billing"), fn ->
      NodeRoles.parse("billing")
    end
  end

  property "concrete roles round-trip from their atom names" do
    check all(role <- member_of(NodeRoles.all())) do
      assert NodeRoles.parse(Atom.to_string(role)) == [role]
    end
  end

  property "unknown alphanumeric roles raise" do
    accepted = Enum.map([:all | NodeRoles.all()], &Atom.to_string/1)

    check all(
            role <- string(:alphanumeric, min_length: 1, max_length: 32),
            role not in accepted
          ) do
      assert_raise ArgumentError, ~s(unknown ZAQ node role: #{inspect(role)}), fn ->
        NodeRoles.parse(role)
      end
    end
  end
end
