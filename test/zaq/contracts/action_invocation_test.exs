defmodule Zaq.Contracts.ActionInvocationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Contracts.ActionInvocation

  property "opaque roots and UUID paths retain their exact identity" do
    check all(
            root <- binary(min_length: 1),
            segments <- list_of(uuid(), min_length: 1, max_length: 5)
          ) do
      path = [root | segments]
      expected = Enum.join(["zaq", Base.url_encode64(root, padding: false) | segments], ".")

      assert ActionInvocation.id([root]) == root
      assert ActionInvocation.valid_path?([root], root)
      assert ActionInvocation.id(path) == expected
      assert ActionInvocation.valid_path?(path, expected)
      refute ActionInvocation.valid_path?(path, expected <> ".other")
      assert Base.url_decode64!(Enum.at(String.split(expected, "."), 1), padding: false) == root
    end
  end

  test "UUID spelling is validated without rewriting segments" do
    segment = "ABCDEF01-2345-6789-ABCD-EF0123456789"
    path = ["native.root", segment]
    id = "zaq.#{Base.url_encode64("native.root", padding: false)}.#{segment}"

    assert ActionInvocation.id(path) == id
    assert ActionInvocation.valid_path?(path, id)
    refute ActionInvocation.valid_path?(path, String.downcase(id))
  end

  test "empty, malformed and non-UUID paths cannot establish an identity" do
    for path <- [nil, [], "root", [""], [nil], [42], ["root", "invalid"], ["root", nil]] do
      refute ActionInvocation.valid_path?(path, "root")
    end
  end

  defp uuid do
    binary(length: 16) |> map(&Ecto.UUID.load!/1)
  end
end
