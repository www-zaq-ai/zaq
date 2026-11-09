defmodule Zaq.Agent.Tools.Workflow.RunAgentAttachmentsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Agent.Tools.Workflow.RunAgent
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Engine.Messages.Outgoing

  setup :verify_on_exit!

  property "workflow attachment results retain signed identity but never content or raw internals" do
    check all(ids <- uniq_list_of(string(:alphanumeric, min_length: 1), max_length: 5)) do
      records =
        Enum.map(ids, fn id ->
          {:ok, record} =
            Provenance.seal(%Record{
              id: id,
              kind: :file,
              content: "private bytes",
              raw: %{credential: "private provider state"}
            })

          record
        end)

      expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{opts: opts} = event ->
        assert opts[:action] == :run_pipeline

        %{
          event
          | response: %Outgoing{
              body: "Files",
              channel_id: "workflow",
              provider: nil,
              attachments: records
            }
        }
      end)

      assert {:ok, %{output: "Files", attachments: attachments}} =
               Jido.Exec.run(
                 RunAgent,
                 %{agent_id: 1, input: "Select files"},
                 %{node_router: Zaq.NodeRouterMock},
                 timeout: 0
               )

      persisted = attachments |> Jason.encode!() |> Jason.decode!()
      assert Enum.map(persisted, & &1["id"]) == ids

      for metadata <- persisted do
        refute Map.has_key?(metadata, "content")
        refute Map.has_key?(metadata, "raw")
        assert {:ok, record} = Record.from_map(metadata)
        assert {:ok, _} = Provenance.verify(record)
      end
    end
  end

  test "rejected attachment selection fails the workflow step instead of becoming a text-only success" do
    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      %{
        event
        | response: %Outgoing{
            body: "Files",
            channel_id: "workflow",
            provider: nil,
            attachment_error: :invalid_attachment_selection
          }
      }
    end)

    assert {:error, "agent_failed:invalid_attachment_selection"} =
             RunAgent.run(%{agent_id: 1, input: "Select files"}, %{
               node_router: Zaq.NodeRouterMock
             })
  end
end
