defmodule ZaqWeb.Live.BO.System.SystemConfig.MCPFeedbackTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Live.BO.System.SystemConfig.MCPFeedback

  describe "test_failure_message/1" do
    test "maps known error families" do
      assert MCPFeedback.test_failure_message(%{details: "Server capabilities not set"}) =~
               "server handshake not ready"

      assert MCPFeedback.test_failure_message(:endpoint_already_registered) =~
               "stale test endpoint state"

      assert MCPFeedback.test_failure_message(%{details: "{:http_error, 401, \"unauthorized\"}"}) =~
               "unauthorized (401)"

      assert MCPFeedback.test_failure_message({:mcp_runtime_call_exit, {:shutdown, :noproc}}) =~
               "client disconnected"

      assert MCPFeedback.test_failure_message(:anything_else) =~
               "MCP tools test failed: :anything_else"
    end
  end

  test "runtime_warnings/1 supports atom and string keys" do
    assert MCPFeedback.runtime_warnings(%{runtime: %{warnings: ["w1"]}}) == ["w1"]
    assert MCPFeedback.runtime_warnings(%{"runtime" => %{"warnings" => ["w2"]}}) == ["w2"]
    assert MCPFeedback.runtime_warnings(%{"runtime" => %{}}) == []
    assert MCPFeedback.runtime_warnings(nil) == []
  end
end
