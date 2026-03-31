defmodule Zaq.Engine.RetrievalSupervisorTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.RetrievalSupervisor

  describe "adapter_for/1" do
    test "returns the Slack adapter module for provider \"slack\"" do
      assert RetrievalSupervisor.adapter_for("slack") ==
               Zaq.Channels.Retrieval.Slack
    end

    test "returns the Email adapter module for provider \"email\"" do
      assert RetrievalSupervisor.adapter_for("email") == nil
    end

    test "returns nil for an unknown provider" do
      assert RetrievalSupervisor.adapter_for("teams") == nil
    end

    test "returns nil for an empty string" do
      assert RetrievalSupervisor.adapter_for("") == nil
    end

    test "returns nil for nil" do
      assert RetrievalSupervisor.adapter_for(nil) == nil
    end
  end
end
