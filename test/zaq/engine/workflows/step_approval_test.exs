defmodule Zaq.Engine.Workflows.StepApprovalTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.StepApproval
  alias Zaq.Repo
  alias Zaq.Test.Stubs

  setup do
    Stubs.stub_node_router()
    :ok
  end

  @valid_source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  defp insert_run! do
    {:ok, workflow} =
      Workflows.create_workflow(%{name: "test-wf-#{System.unique_integer()}", status: "draft"})

    {:ok, run} = Workflows.create_run(workflow, @valid_source_event)
    {:ok, run} = Workflows.update_run(run, %{status: "waiting"})
    run
  end

  defp valid_attrs(run) do
    %{
      workflow_run_id: run.id,
      step_name: "approval_step",
      approval_token: Ecto.UUID.generate(),
      message: "Please review",
      status: "pending"
    }
  end

  describe "changeset/2 — valid" do
    test "accepts valid attrs" do
      run = insert_run!()
      cs = StepApproval.changeset(%StepApproval{}, valid_attrs(run))
      assert cs.valid?
    end

    test "message is optional" do
      run = insert_run!()
      attrs = valid_attrs(run) |> Map.delete(:message)
      cs = StepApproval.changeset(%StepApproval{}, attrs)
      assert cs.valid?
    end

    test "decision, approved_by, approved_at are optional" do
      run = insert_run!()
      cs = StepApproval.changeset(%StepApproval{}, valid_attrs(run))
      assert cs.valid?
    end
  end

  describe "changeset/2 — required fields" do
    test "missing workflow_run_id is invalid" do
      run = insert_run!()

      cs =
        StepApproval.changeset(
          %StepApproval{},
          valid_attrs(run) |> Map.delete(:workflow_run_id)
        )

      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :workflow_run_id)
    end

    test "missing step_name is invalid" do
      run = insert_run!()

      cs =
        StepApproval.changeset(
          %StepApproval{},
          valid_attrs(run) |> Map.delete(:step_name)
        )

      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :step_name)
    end

    test "missing approval_token is invalid" do
      run = insert_run!()

      cs =
        StepApproval.changeset(
          %StepApproval{},
          valid_attrs(run) |> Map.delete(:approval_token)
        )

      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :approval_token)
    end
  end

  describe "changeset/2 — status validation" do
    test "accepts all valid statuses" do
      run = insert_run!()

      for status <- ~w(pending approved rejected) do
        cs =
          StepApproval.changeset(
            %StepApproval{},
            Map.put(valid_attrs(run), :status, status)
          )

        assert cs.valid?, "expected #{status} to be valid"
      end
    end

    test "rejects unknown status" do
      run = insert_run!()

      cs =
        StepApproval.changeset(
          %StepApproval{},
          Map.put(valid_attrs(run), :status, "unknown")
        )

      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :status)
    end
  end

  describe "unique constraints" do
    test "duplicate approval_token raises constraint error" do
      run = insert_run!()
      token = Ecto.UUID.generate()
      attrs = Map.put(valid_attrs(run), :approval_token, token)
      {:ok, _} = Repo.insert(StepApproval.changeset(%StepApproval{}, attrs))

      run2 = insert_run!()
      attrs2 = %{valid_attrs(run2) | approval_token: token}
      {:error, cs} = Repo.insert(StepApproval.changeset(%StepApproval{}, attrs2))
      assert cs.errors[:approval_token]
    end

    test "duplicate (workflow_run_id, step_name) raises constraint error" do
      run = insert_run!()
      attrs = valid_attrs(run)
      {:ok, _} = Repo.insert(StepApproval.changeset(%StepApproval{}, attrs))

      attrs2 = Map.put(attrs, :approval_token, Ecto.UUID.generate())
      {:error, cs} = Repo.insert(StepApproval.changeset(%StepApproval{}, attrs2))
      assert cs.errors[:step_name] || cs.errors[:workflow_run_id]
    end
  end

  describe "statuses/0" do
    test "returns the valid status list" do
      assert StepApproval.statuses() == ~w(pending approved rejected)
    end
  end
end
