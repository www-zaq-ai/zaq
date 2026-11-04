defmodule Zaq.Agent.AttachmentSelectionEventTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.{Factory, OpaqueAliases, StreamEvents}
  alias Zaq.Agent.Tools.DataSource.AttachDocuments
  alias Zaq.Contracts.{Record, ToolStep}
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Engine.Messages.Incoming

  setup do
    scope = make_ref()
    on_exit(fn -> OpaqueAliases.clear_scope(scope) end)
    %{scope: scope}
  end

  test "completion results own selection, suppress replay and stop at termination", %{
    scope: scope
  } do
    add = selection(scope, "add-a", "add", [record("a")])
    remove = selection(scope, "remove-a", "remove", [record("a")])
    b = selection(scope, "add-b", "add", [record("b")])
    foreign = %{add | request_id: "foreign", tool_call_id: "foreign"}

    assert {:ok, result} = consume([add, remove, add, foreign, b, completed(), add], scope)
    assert [%Record{id: "b"}] = result.attachments
    assert Enum.count(result.tool_calls, &(&1["name"] == "attach_documents")) == 3

    public = ToolStep.project(result.tool_calls)

    for step <- public do
      refute Map.has_key?(step, "arguments")
      refute Map.has_key?(step, "response")
      refute inspect(step) =~ "provenance"
    end

    assert {:ok, %{attachments: []}} = consume([completed()], scope)
  end

  test "failed tools do not mutate and failed or incomplete requests expose no files", %{
    scope: scope
  } do
    add = selection(scope, "add-a", "add", [record("a")])

    failed = %{
      selection(scope, "clear", "replace", [])
      | data: %{result: {:error, :unauthorized, []}}
    }

    assert {:ok, %{attachments: [%Record{id: "a"}]}} = consume([add, failed, completed()], scope)
    assert {:ok, %{attachments: []}} = consume([add], scope)

    for kind <- [:request_failed, :request_cancelled] do
      assert {:error, _, %{attachments: []}} =
               consume([add, %{kind: kind, request_id: "r", data: %{error: :failed}}], scope)
    end
  end

  test "missing, foreign and retired alias scopes fail closed", %{scope: scope} do
    event = selection(scope, "add-a", "add", [record("a")])

    for wrong_scope <- [nil, make_ref()] do
      assert {:ok,
              %{answer: "Done", attachment_error: :invalid_attachment_selection, attachments: []}} =
               consume([event, completed()], wrong_scope)
    end

    OpaqueAliases.clear_scope(scope)

    assert {:ok,
            %{answer: "Done", attachment_error: :invalid_attachment_selection, attachments: []}} =
             consume([event, completed()], scope)
  end

  test "malformed successful instructions reject the whole batch", %{scope: scope} do
    valid = selection(scope, "add-a", "add", [record("a")])

    for output <- [
          "invalid",
          %{operation: "delete", records: []},
          %{operation: "add", records: [%{"id" => "unsigned"}]},
          %{operation: "replace", records: "invalid"}
        ] do
      invalid = %{valid | tool_call_id: "invalid", data: %{result: {:ok, output, []}}}

      assert {:ok,
              %{answer: "Done", attachment_error: :invalid_attachment_selection, attachments: []}} =
               consume([valid, invalid, completed()], scope)
    end
  end

  test "structured tool results retain validated selection without exposing it in public steps",
       %{scope: scope} do
    event = selection(scope, "structured", "add", [record("structured-record")])
    {:ok, output, []} = event.data.result
    event = %{event | data: %{result: {:ok, %ReqLLM.ToolResult{output: output}, []}}}

    assert {:ok, result} = consume([event, completed()], scope)
    assert [%Record{id: "structured-record"}] = result.attachments
    refute inspect(ToolStep.project(result.tool_calls)) =~ "structured-record"
  end

  defp selection(scope, id, operation, records) do
    assert {:ok, {:ok, output, []}} =
             Factory.after_tool_call(
               %{action_module: AttachDocuments},
               {:ok, %{operation: operation, records: records}, []},
               %{opaque_alias_scope: scope}
             )

    %{
      kind: :tool_completed,
      request_id: "r",
      tool_call_id: id,
      tool_name: "attach_documents",
      data: %{result: {:ok, output, []}}
    }
  end

  defp consume(events, scope) do
    StreamEvents.consume(
      Stream.filter(events, &(&1.request_id == "r")),
      %Incoming{content: "select", channel_id: "c", provider: :web, message_id: "r"},
      opaque_alias_scope: scope,
      request: %{id: "r"},
      status_module: Zaq.TestSupport.NoopAgentStatus
    )
  end

  defp completed, do: %{kind: :request_completed, request_id: "r", data: %{result: "Done"}}

  defp record(id) do
    {:ok, record} = Provenance.seal(%Record{id: id, kind: :file})
    record
  end
end
