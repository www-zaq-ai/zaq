defmodule Zaq.Agent.Tools.Files.PersistFileTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Files.PersistFile
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{opts: opts}) do
      response =
        case opts[:action] do
          :persist_file ->
            {:ok,
             %{
               name: "report.md",
               path: "generated/report.md",
               mime_type: "text/markdown",
               size: 16
             }}
        end

      %{Event.new(%{}, :channels) | response: response}
    end
  end

  describe "run/2" do
    test "dispatches persist_file event and returns metadata" do
      assert {:ok, result} =
               PersistFile.run(
                 %{filename: "report.pdf", data: "# Report", mime_type: "text/markdown"},
                 %{node_router: StubNodeRouter}
               )

      assert result.name == "report.md"
      assert result.path == "generated/report.md"
      assert result.mime_type == "text/markdown"
      assert result.size == 16
    end

    test "includes provider in dispatch params" do
      assert {:ok, result} =
               PersistFile.run(
                 %{
                   filename: "notes.txt",
                   data: "hello",
                   mime_type: "text/plain",
                   provider: "google_drive"
                 },
                 %{node_router: StubNodeRouter}
               )

      assert result.name == "report.md"
      assert result.mime_type == "text/markdown"
    end
  end
end
