defmodule Zaq.Engine.Workflows.WorkflowRunTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows.WorkflowRun

  defp base_attrs do
    %{
      workflow_id: Ecto.UUID.generate(),
      steps_snapshot: %{"nodes" => [], "edges" => []},
      source_event: %{
        "request" => nil,
        "assigns" => %{"trigger_type" => "manual"},
        "trace_id" => Ecto.UUID.generate()
      },
      status: "pending"
    }
  end

  describe "changeset/2 — status validation" do
    test "accepts 'paused' status" do
      cs = WorkflowRun.changeset(%WorkflowRun{}, Map.put(base_attrs(), :status, "paused"))
      assert cs.valid?
    end

    test "accepts 'waiting' status" do
      cs = WorkflowRun.changeset(%WorkflowRun{}, Map.put(base_attrs(), :status, "waiting"))
      assert cs.valid?
    end

    test "accepts all other valid statuses" do
      for status <- ~w(pending running completed failed) do
        cs = WorkflowRun.changeset(%WorkflowRun{}, Map.put(base_attrs(), :status, status))
        assert cs.valid?, "expected #{status} to be valid"
      end
    end

    test "rejects an arbitrary status string" do
      cs = WorkflowRun.changeset(%WorkflowRun{}, Map.put(base_attrs(), :status, "on_hold"))
      refute cs.valid?
      assert {:status, _} = hd(cs.errors)
    end

    test "statuses/0 includes 'paused'" do
      assert "paused" in WorkflowRun.statuses()
    end
  end
end
