defmodule Zaq.Ingestion.ContentSourceTest do
  use ExUnit.Case, async: true

  alias Zaq.Ingestion.ContentSource

  describe "from_source/1" do
    test "parses a file source" do
      result = ContentSource.from_source("documents/hr/policy.md")

      assert %ContentSource{
               connector: "documents",
               source_prefix: "documents/hr/policy.md",
               label: "policy.md",
               type: :file
             } = result
    end

    test "parses a folder source" do
      result = ContentSource.from_source("documents/hr")

      assert %ContentSource{
               connector: "documents",
               source_prefix: "documents/hr",
               label: "hr",
               type: :folder
             } = result
    end

    test "parses a connector-only source" do
      result = ContentSource.from_source("sharepoint")

      assert %ContentSource{
               connector: "sharepoint",
               source_prefix: "sharepoint",
               label: "sharepoint",
               type: :connector
             } = result
    end

    test "parses a deeply nested file from a future connector" do
      result = ContentSource.from_source("sharepoint/sites/hr/policy.docx")

      assert %ContentSource{
               connector: "sharepoint",
               source_prefix: "sharepoint/sites/hr/policy.docx",
               label: "policy.docx",
               type: :file
             } = result
    end

    test "parses a gdrive file source" do
      result = ContentSource.from_source("gdrive/shared/reports/q4.pdf")

      assert %ContentSource{
               connector: "gdrive",
               source_prefix: "gdrive/shared/reports/q4.pdf",
               label: "q4.pdf",
               type: :file
             } = result
    end

    test "parses a folder with no extension in last segment" do
      result = ContentSource.from_source("documents/reports/annual-report")

      assert %ContentSource{connector: "documents", type: :folder, label: "annual-report"} =
               result
    end

    test "returns nil for empty string" do
      assert is_nil(ContentSource.from_source(""))
    end

    test "returns nil for nil" do
      assert is_nil(ContentSource.from_source(nil))
    end

    test "returns nil for slash-only string (all segments trimmed away)" do
      assert is_nil(ContentSource.from_source("/"))
    end
  end
end
