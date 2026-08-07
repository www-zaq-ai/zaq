defmodule ZaqWeb.Components.AgentTracePanelArtifactTest do
  # The chip is drawn from the trace entry alone — no query, no bytes — so these cover the
  # extraction and formatting rather than the markup.
  use ExUnit.Case, async: true

  alias ZaqWeb.Components.AgentTracePanel

  defp entry(record) do
    %{"id" => "call_1", "type" => "tool_call", "response" => %{"record" => record}}
  end

  describe "trace_artifact/1" do
    test "reads the chip from what the tool result kept" do
      trace =
        entry(%{
          "name" => "photo.png",
          "mime_type" => "image/png",
          "size" => 113_000,
          "attributes" => %{"trace_artifact_id" => "abc-123"}
        })

      assert AgentTracePanel.trace_artifact(trace) == %{
               id: "abc-123",
               name: "photo.png",
               mime_type: "image/png",
               size: 113_000
             }
    end

    test "a file the provider never named still draws" do
      trace = entry(%{"attributes" => %{"trace_artifact_id" => "abc-123"}})

      assert %{name: "attachment"} = AgentTracePanel.trace_artifact(trace)
    end

    test "a tool that stored nothing has no chip" do
      assert AgentTracePanel.trace_artifact(entry(%{"name" => "photo.png"})) == nil
    end

    test "an empty artifact id is no chip, not a broken link" do
      trace = entry(%{"attributes" => %{"trace_artifact_id" => ""}})

      assert AgentTracePanel.trace_artifact(trace) == nil
    end

    test "a listing response has no record and no chip" do
      assert AgentTracePanel.trace_artifact(%{"response" => %{"attachments" => []}}) == nil
    end

    test "an llm trace entry has no chip" do
      assert AgentTracePanel.trace_artifact(%{"type" => "reasoning"}) == nil
    end

    test "a non-map entry does not crash the panel" do
      assert AgentTracePanel.trace_artifact("nope") == nil
    end
  end

  describe "artifact_icon/1" do
    test "picks an icon from what the bytes were sniffed as" do
      assert AgentTracePanel.artifact_icon("image/png") == "hero-photo"
      assert AgentTracePanel.artifact_icon("audio/ogg") == "hero-musical-note"
      assert AgentTracePanel.artifact_icon("video/mp4") == "hero-film"
      assert AgentTracePanel.artifact_icon("application/pdf") == "hero-document"
    end

    test "an unknown type still gets an icon" do
      assert AgentTracePanel.artifact_icon(nil) == "hero-document"
    end
  end

  describe "format_bytes/1" do
    test "scales to what a reviewer reads" do
      assert AgentTracePanel.format_bytes(512) == "512 B"
      assert AgentTracePanel.format_bytes(2048) == "2.0 KB"
      assert AgentTracePanel.format_bytes(113_000) == "110.4 KB"
      assert AgentTracePanel.format_bytes(5_242_880) == "5.0 MB"
    end

    test "a size the provider never gave shows nothing rather than zero" do
      assert AgentTracePanel.format_bytes(nil) == nil
    end
  end
end
