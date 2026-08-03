defmodule Zaq.Agent.Skill.ReferenceFilesTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Skill
  alias Zaq.Agent.Skill.ReferenceFiles
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Event

  defmodule ListRouter do
    def dispatch(%Event{request: %{provider: provider, params: params}, opts: opts} = event) do
      send(self(), {:listed, provider, opts[:action], params["file_ids"]})

      records =
        Enum.map(params["file_ids"], fn id ->
          %Record{id: id, kind: :file, name: "#{provider}-#{id}.md", content: nil}
        end)

      %{event | response: {:ok, %RecordPage{resource_type: :file, records: records}}}
    end
  end

  defmodule FailingRouter do
    def dispatch(%Event{} = event), do: %{event | response: {:error, :ingestion_unreachable}}
  end

  defmodule MixedRouter do
    alias Zaq.Agent.Skill.ReferenceFilesTest.FailingRouter
    alias Zaq.Agent.Skill.ReferenceFilesTest.ListRouter

    def dispatch(%Event{request: %{provider: "gdrive"}} = event),
      do: FailingRouter.dispatch(event)

    def dispatch(%Event{} = event), do: ListRouter.dispatch(event)
  end

  defp skill(references) do
    %Skill{id: 1, name: "pricing-faq", resources: %{"references" => references}}
  end

  defp reference(file_id, provider), do: %{"file_id" => file_id, "provider" => provider}

  describe "list/2" do
    test "returns each file paired with the provider it was requested from" do
      skill = skill([reference("7", "disk"), reference("9", "disk")])

      assert [{"disk", %Record{id: "7"}}, {"disk", %Record{id: "9"}}] =
               ReferenceFiles.list(skill, node_router: ListRouter)

      assert_received {:listed, "disk", :data_source_list_files, ["7", "9"]}
    end

    test "dispatches once per provider, not once per file" do
      skill =
        skill([
          reference("1", "disk"),
          reference("2", "gdrive"),
          reference("3", "disk")
        ])

      result = ReferenceFiles.list(skill, node_router: ListRouter)

      assert length(result) == 3
      assert_received {:listed, "disk", _action, ["1", "3"]}
      assert_received {:listed, "gdrive", _action, ["2"]}
      refute_received {:listed, _provider, _action, _ids}
    end

    test "pairs each record with its own provider when several are referenced" do
      skill = skill([reference("1", "disk"), reference("2", "gdrive")])

      named =
        skill
        |> ReferenceFiles.list(node_router: ListRouter)
        |> Enum.map(fn {provider, record} -> {provider, record.name} end)

      assert {"disk", "disk-1.md"} in named
      assert {"gdrive", "gdrive-2.md"} in named
    end

    test "a skill with no references dispatches nothing" do
      assert ReferenceFiles.list(skill([]), node_router: ListRouter) == []
      refute_received {:listed, _provider, _action, _ids}
    end

    test "an unreachable provider yields no records rather than an error" do
      skill = skill([reference("7", "disk")])

      assert ReferenceFiles.list(skill, node_router: FailingRouter) == []
    end

    test "reports the failure to :on_error when the caller asks" do
      skill = skill([reference("7", "disk")])
      parent = self()

      assert ReferenceFiles.list(skill,
               node_router: FailingRouter,
               on_error: fn provider, response -> send(parent, {:failed, provider, response}) end
             ) == []

      assert_received {:failed, "disk", {:error, :ingestion_unreachable}}
    end

    test "a failing provider does not suppress one that answers" do
      skill = skill([reference("1", "disk"), reference("2", "gdrive")])

      assert [{"disk", %Record{id: "1"}}] = ReferenceFiles.list(skill, node_router: MixedRouter)
    end
  end

  # A reference whose document was deleted outside the BO comes back as a shorter page, not
  # an error. Nothing distinguishes that from a skill that never had the file, so the gap is
  # reported rather than left to be inferred from a list length.
  describe "missing references" do
    defmodule PartialRouter do
      def dispatch(%Event{} = event) do
        page = %RecordPage{
          resource_type: :file,
          records: [%Record{id: "1", kind: :file, name: "1.md"}],
          stats: %{scanned: 2, returned: 1, missing: ["2"]}
        }

        %{event | response: {:ok, page}}
      end
    end

    test "reports ids the provider omitted to :on_error" do
      skill = skill([reference("1", "disk"), reference("2", "disk")])
      parent = self()

      assert [{"disk", %Record{id: "1"}}] =
               ReferenceFiles.list(skill,
                 node_router: PartialRouter,
                 on_error: fn provider, reason -> send(parent, {:gap, provider, reason}) end
               )

      assert_received {:gap, "disk", {:missing_references, ["2"]}}
    end

    test "says nothing when every id resolved" do
      parent = self()

      ReferenceFiles.list(skill([reference("7", "disk")]),
        node_router: ListRouter,
        on_error: fn provider, reason -> send(parent, {:gap, provider, reason}) end
      )

      refute_received {:gap, _provider, _reason}
    end
  end
end
