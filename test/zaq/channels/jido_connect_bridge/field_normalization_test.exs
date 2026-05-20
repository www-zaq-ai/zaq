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

  test "preserves explicit mime_type when export_mime_type is also present" do
    params = %{"mime_type" => "application/pdf", "export_mime_type" => "text/plain"}

    assert FieldNormalization.normalize_all("google_drive", "google.drive.file.export", params) ==
             %{"mime_type" => "application/pdf", "export_mime_type" => "text/plain"}
  end
end
