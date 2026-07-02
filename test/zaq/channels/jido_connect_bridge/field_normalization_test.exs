defmodule Zaq.Channels.JidoConnectBridge.FieldNormalizationTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.JidoConnectBridge.FieldNormalization

  test "normalize_all keeps values when no specific rule matches" do
    params = %{"query" => "invoice", "page_size" => 10}

    assert FieldNormalization.normalize_all("sharepoint", "sharepoint.files.search", params) ==
             params
  end

  test "normalizes plain text query for google drive list files action" do
    params = %{"query" => "Staas"}

    assert FieldNormalization.normalize_all("google_drive", "google.drive.files.list", params) ==
             %{"query" => "name contains 'Staas'"}
  end

  test "escapes single quotes in compiled google drive query" do
    params = %{"query" => "John's notes"}

    assert FieldNormalization.normalize_all("google_drive", "google.drive.files.list", params) ==
             %{"query" => "name contains 'John\\'s notes'"}
  end

  test "does not rewrite existing drive DSL query" do
    params = %{"query" => "name contains 'Staas' and trashed = false"}

    assert FieldNormalization.normalize_all("google_drive", "google.drive.files.list", params) ==
             params
  end

  test "normalizes :q and :query atom keys" do
    params = %{q: "Staas", query: "Staas"}

    assert FieldNormalization.normalize_all(:google_drive, "google.drive.files.list", params) ==
             %{q: "name contains 'Staas'", query: "name contains 'Staas'"}
  end

  test "maps export_mime_type to mime_type for google drive export action" do
    params = %{"export_mime_type" => "text/plain"}

    assert FieldNormalization.normalize_all("google_drive", "google.drive.file.export", params) ==
             %{"mime_type" => "text/plain"}
  end

  test "preserves explicit mime_type while keeping export_mime_type when both are present" do
    params = %{export_mime_type: "text/plain", mime_type: "application/pdf"}

    assert FieldNormalization.normalize_all(:google_drive, "google.drive.file.export", params) ==
             %{mime_type: "application/pdf", export_mime_type: "text/plain"}

    result = FieldNormalization.normalize_all(:google_drive, "google.drive.file.export", params)

    assert result[:mime_type] == "application/pdf"
    assert result[:export_mime_type] == "text/plain"
    refute Map.has_key?(result, nil)
  end

  test "preserves explicit mime_type when export_mime_type is also present" do
    params = %{"mime_type" => "application/pdf", "export_mime_type" => "text/plain"}

    assert FieldNormalization.normalize_all("google_drive", "google.drive.file.export", params) ==
             %{"mime_type" => "application/pdf", "export_mime_type" => "text/plain"}
  end

  test "normalizes atom export_mime_type key to atom mime_type for google drive export action" do
    params = %{export_mime_type: "text/plain"}

    assert FieldNormalization.normalize_all(:google_drive, "google.drive.file.export", params) ==
             %{mime_type: "text/plain"}

    result = FieldNormalization.normalize_all(:google_drive, "google.drive.file.export", params)

    refute Map.has_key?(result, :export_mime_type)
    refute Map.has_key?(result, "mime_type")
  end

  test "maps parent_id to parents for google drive file create" do
    params = %{"name" => "Doc", "parent_id" => "folder-1"}

    assert FieldNormalization.normalize_all("google_drive", "google.drive.file.create", params) ==
             %{"name" => "Doc", "parents" => ["folder-1"]}
  end

  test "maps parent_id to parents for google drive folder create" do
    params = %{name: "Folder", parent_id: "folder-1"}

    assert FieldNormalization.normalize_all(:google_drive, "google.drive.folder.create", params) ==
             %{name: "Folder", parents: ["folder-1"]}
  end

  test "preserves explicit parents over parent_id for google drive create" do
    params = %{"name" => "Doc", "parent_id" => "folder-1", "parents" => ["folder-2"]}

    assert FieldNormalization.normalize_all("google_drive", "google.drive.file.create", params) ==
             %{"name" => "Doc", "parents" => ["folder-2"]}
  end

  test "does not map parent_id for google drive update" do
    params = %{"file_id" => "doc-1", "parent_id" => "folder-1"}

    assert FieldNormalization.normalize_all("google_drive", "google.drive.file.update", params) ==
             params
  end

  test "drops blank parent_id for google drive create" do
    params = %{"name" => "Doc", "parent_id" => "  "}

    assert FieldNormalization.normalize_all("google_drive", "google.drive.file.create", params) ==
             %{"name" => "Doc"}
  end
end
