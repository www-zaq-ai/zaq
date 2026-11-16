defmodule Zaq.Engine.Extension.ActionsTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Registry
  alias Zaq.Engine.Extension.{Actions, Invocation}
  alias Zaq.Engine.Extension.Rpc.Gateway.V1.ActionFailure

  test "list reuses Registry metadata and pagination without loading schemas" do
    assert {:listed, page} = Actions.execute(%Invocation{operation: :list, page_size: 2})
    assert length(page.actions) == 2
    assert Enum.map(page.actions, & &1.key) == Registry.keys() |> Enum.sort() |> Enum.take(2)
    refute Map.has_key?(hd(page.actions), :input_schema_json)
    assert page.next_page_token == List.last(page.actions).key

    assert {:listed, next} =
             Actions.execute(%Invocation{
               operation: :list,
               page_size: 2,
               page_token: page.next_page_token
             })

    assert hd(next.actions).key > page.next_page_token
  end

  test "describe exports the existing Action schema and execute uses Jido validation" do
    assert {:described, description} =
             Actions.execute(%Invocation{operation: :describe, key: "arithmetic.add"})

    assert description.metadata.key == "arithmetic.add"
    assert Jason.decode!(description.input_schema_json)["properties"]["amount"]

    assert {:failure, %ActionFailure{code: :RESULT_NOT_SERIALIZABLE}} =
             Actions.execute(%Invocation{
               operation: :describe,
               key: "arithmetic.add",
               max_json_depth: 1
             })

    assert {:result_json, json} =
             Actions.execute(%Invocation{
               operation: :execute,
               key: "arithmetic.add",
               arguments_json: ~s({"value":2.0,"amount":3.0})
             })

    assert Jason.decode!(json) == %{"result" => 5.0}

    assert {:failure, %ActionFailure{code: :INVALID_ARGUMENT}} =
             Actions.execute(%Invocation{
               operation: :execute,
               key: "arithmetic.add",
               arguments_json: "{}"
             })
  end

  test "unknown keys, non-object JSON and excessive nesting fail safely" do
    assert {:failure, %ActionFailure{code: :UNKNOWN_ACTION}} =
             Actions.execute(%Invocation{operation: :describe, key: "not.registered"})

    for json <- ["[]", "null", "{broken", <<255>>, ~s({"nested":{"again":{}}})] do
      assert {:failure, %ActionFailure{code: :INVALID_ARGUMENT, effects_may_have_occurred: false}} =
               Actions.execute(%Invocation{
                 operation: :execute,
                 key: "arithmetic.add",
                 arguments_json: json,
                 max_json_depth: 2
               })
    end
  end

  test "unknown input keys are never interned as atoms" do
    key = "untrusted_#{Ecto.UUID.generate()}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end

    Actions.execute(%Invocation{
      operation: :execute,
      key: "arithmetic.add",
      arguments_json: Jason.encode!(%{"value" => 2.0, "amount" => 3.0, key => "private"})
    })

    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
  end

  test "existing schema enums and atom-valued results use their JSON string representation" do
    assert {:result_json, json} =
             Actions.execute(%Invocation{
               operation: :execute,
               key: "basic.today",
               arguments_json: ~s({"format":"iso8601"})
             })

    assert Jason.decode!(json) == %{
             "format" => "iso8601",
             "date" => Date.to_iso8601(Date.utc_today())
           }
  end
end
