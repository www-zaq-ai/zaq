defmodule Zaq.Engine.Connect.PersonLifecycleGuardTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Connect.PersonLifecycle

  test "delete_people requires an identity transaction" do
    assert_raise ArgumentError, "Person lifecycle requires an identity transaction", fn ->
      PersonLifecycle.delete_people([])
    end
  end

  test "merge_people requires an identity transaction" do
    assert_raise ArgumentError, "Person lifecycle requires an identity transaction", fn ->
      PersonLifecycle.merge_people(1, [])
    end
  end
end
