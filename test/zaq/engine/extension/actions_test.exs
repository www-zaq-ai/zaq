defmodule Zaq.Engine.Extension.ActionsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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

  test "execute failures expose only safe outcomes and preserve side-effect uncertainty" do
    input = String.duplicate("x", 384)

    assert {:failure,
            %ActionFailure{
              code: :ACTION_FAILED,
              effects_may_have_occurred: true,
              safe_message: ""
            }} =
             Actions.execute(%Invocation{
               operation: :execute,
               key: "general.decode_json",
               arguments_json: Jason.encode!(%{"data" => ~s({"private-marker": })})
             })

    assert {:failure,
            %ActionFailure{
              code: :RESULT_TOO_LARGE,
              effects_may_have_occurred: true,
              safe_message: ""
            }} =
             Actions.execute(%Invocation{
               operation: :execute,
               key: "general.encode_base64",
               arguments_json: Jason.encode!(%{"data" => input}),
               max_result_bytes: 525
             })

    assert {:result_json, json} =
             Actions.execute(%Invocation{
               operation: :execute,
               key: "general.encode_base64",
               arguments_json: Jason.encode!(%{"data" => input}),
               max_result_bytes: 526
             })

    assert byte_size(json) == 526
    assert Jason.decode!(json)["encoded"] |> Base.decode64!() == input

    nested_json = Jason.encode!(%{"data" => Jason.encode!(%{"private" => "depth-marker"})})

    assert {:failure,
            %ActionFailure{
              code: :RESULT_NOT_SERIALIZABLE,
              effects_may_have_occurred: true,
              safe_message: ""
            }} =
             Actions.execute(%Invocation{
               operation: :execute,
               key: "general.decode_json",
               arguments_json: nested_json,
               max_json_depth: 1
             })

    assert {:result_json, decoded_json} =
             Actions.execute(%Invocation{
               operation: :execute,
               key: "general.decode_json",
               arguments_json: nested_json,
               max_json_depth: 2
             })

    assert Jason.decode!(decoded_json) == %{"decoded" => %{"private" => "depth-marker"}}

    assert {:failure,
            %ActionFailure{
              code: :UNKNOWN_ACTION,
              effects_may_have_occurred: false,
              safe_message: ""
            }} =
             Actions.execute(%Invocation{
               operation: :execute,
               key: "Elixir.Jido.Tools.Arithmetic.Add",
               arguments_json: ~s({"value":2.0,"amount":3.0})
             })
  end

  test "list rejects invalid pagination arguments with safe failures" do
    for {page_size, page_token} <- [{101, ""}, {1, String.duplicate("x", 257)}, {1, <<255>>}] do
      assert {:failure,
              %ActionFailure{
                code: :INVALID_ARGUMENT,
                effects_may_have_occurred: false,
                safe_message: ""
              }} =
               Actions.execute(%Invocation{
                 operation: :list,
                 page_size: page_size,
                 page_token: page_token
               })
    end
  end

  test "describe exposes the base64 output schema" do
    assert {:described, description} =
             Actions.execute(%Invocation{operation: :describe, key: "general.encode_base64"})

    assert description.metadata.key == "general.encode_base64"

    assert Jason.decode!(description.output_schema_json)["properties"]["encoded"]["type"] ==
             "string"
  end

  test "event handling enforces confidential entry and completion contracts" do
    invocation = %Invocation{
      operation: :execute,
      key: "arithmetic.add",
      arguments_json: ~s({"value":2.0,"amount":3.0})
    }

    non_confidential =
      Zaq.Event.new(invocation, :engine, opts: [action: :extension_action, confidential: false])

    assert %{response: {:error, :confidential_event_required}} =
             Actions.handle_event(non_confidential)

    missing_confidential =
      Zaq.Event.new(%Invocation{operation: :execute, key: "arithmetic.add"}, :engine,
        opts: [action: :extension_action]
      )

    assert %{response: {:error, :confidential_event_required}} =
             Actions.handle_event(missing_confidential)

    generation = make_ref()
    trace_id = Ecto.UUID.generate()
    assigns = %{extension_owner: self(), extension_generation: generation}

    completion =
      Zaq.Event.new(:completed, :engine,
        trace_id: trace_id,
        assigns: assigns,
        opts: [action: :extension_action_completed, confidential: true]
      )

    assert %{response: :ok} = Actions.deliver_completion(completion)
    assert_receive {:extension_action_completed, ^generation, ^trace_id, :completed}

    invalid_completion_assigns = [
      %{},
      %{extension_owner: :not_a_pid, extension_generation: generation},
      %{extension_owner: self(), extension_generation: :not_a_reference}
    ]

    for invalid_assigns <- invalid_completion_assigns do
      invalid_trace_id = Ecto.UUID.generate()
      invalid_generation = make_ref()

      invalid_completion = %{
        completion
        | trace_id: invalid_trace_id,
          assigns: Map.put_new(invalid_assigns, :extension_generation, invalid_generation)
      }

      expected_generation = invalid_completion.assigns.extension_generation

      assert %{response: {:error, :invalid_completion}} =
               Actions.deliver_completion(invalid_completion)

      refute_receive {:extension_action_completed, ^expected_generation, ^invalid_trace_id, _}
    end

    missing_confidential_completion = %{
      completion
      | trace_id: Ecto.UUID.generate(),
        assigns: %{extension_owner: self(), extension_generation: make_ref()},
        opts: [action: :extension_action_completed]
    }

    missing_generation = missing_confidential_completion.assigns.extension_generation
    missing_trace_id = missing_confidential_completion.trace_id

    assert %{response: {:error, :invalid_completion}} =
             Actions.deliver_completion(missing_confidential_completion)

    refute_receive {:extension_action_completed, ^missing_generation, ^missing_trace_id, _}
  end

  property "non-true confidentiality never authorizes either event entry point" do
    check all(
            confidentiality <-
              StreamData.one_of([
                StreamData.member_of([false, nil, :untrusted]),
                StreamData.binary(),
                StreamData.integer(),
                StreamData.list_of(StreamData.integer())
              ]),
            max_runs: 30
          ) do
      check_confidential_event_entry(confidentiality)
    end
  end

  test "execute restores the process Logger level, including an unset override" do
    original_level = Logger.get_process_level(self())

    try do
      Logger.put_process_level(self(), :warning)

      assert {:failure,
              %ActionFailure{
                code: :ACTION_FAILED,
                effects_may_have_occurred: true,
                safe_message: ""
              }} =
               Actions.execute(%Invocation{
                 operation: :execute,
                 key: "general.decode_json",
                 arguments_json: Jason.encode!(%{"data" => ~s({"private-marker": })})
               })

      assert Logger.get_process_level(self()) == :warning

      Logger.delete_process_level(self())
      assert Logger.get_process_level(self()) == nil

      assert {:failure,
              %ActionFailure{
                code: :ACTION_FAILED,
                effects_may_have_occurred: true,
                safe_message: ""
              }} =
               Actions.execute(%Invocation{
                 operation: :execute,
                 key: "general.decode_json",
                 arguments_json: Jason.encode!(%{"data" => ~s({"private-marker": })})
               })

      assert Logger.get_process_level(self()) == nil
    after
      if original_level,
        do: Logger.put_process_level(self(), original_level),
        else: Logger.delete_process_level(self())
    end
  end

  defp check_confidential_event_entry(confidentiality) do
    invocation = %Invocation{
      operation: :execute,
      key: "arithmetic.add",
      arguments_json: ~s({"value":2.0,"amount":3.0})
    }

    event =
      Zaq.Event.new(invocation, :engine,
        opts: [action: :extension_action, confidential: confidentiality]
      )

    assert %{response: {:error, :confidential_event_required}} = Actions.handle_event(event)

    trace_id = Ecto.UUID.generate()
    generation = make_ref()

    completion =
      Zaq.Event.new(:completed, :engine,
        trace_id: trace_id,
        assigns: %{extension_owner: self(), extension_generation: generation},
        opts: [action: :extension_action_completed, confidential: confidentiality]
      )

    assert %{response: {:error, :invalid_completion}} = Actions.deliver_completion(completion)
    refute_receive {:extension_action_completed, ^generation, ^trace_id, _}
  end
end
