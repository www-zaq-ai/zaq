defmodule ZaqWeb.PreviewReferenceTest do
  use ExUnit.Case, async: true

  alias Zaq.Contracts.Record
  alias ZaqWeb.PreviewReference

  test "sign_record/2 returns nil when record has no materialization handle" do
    record = %Record{id: "record-1", kind: :file}

    assert PreviewReference.sign_record(record, %{id: "user-1"}) == nil
  end

  test "derives filename from path and accepts string-keyed user identity" do
    record = %Record{
      id: "record-1",
      kind: :file,
      path: "/archive/quarterly/report.pdf",
      attributes: nil,
      materialization_handle: "handle-1"
    }

    token = PreviewReference.sign_record(record, %{"id" => "user-1"})
    assert {:ok, payload} = PreviewReference.verify(token, %{"id" => "user-1"})

    assert payload["filename"] == "report.pdf"
    assert payload["source"] == "/archive/quarterly/report.pdf"
    assert payload["handle"] == "handle-1"
    assert payload["user_id"] == "user-1"
    assert payload["v"] == 1
    assert payload["type"] == "record"
  end

  test "uses record id for filename when path is absent" do
    record = %Record{
      id: "generated.txt",
      kind: :file,
      materialization_handle: "handle-1"
    }

    token = PreviewReference.sign_record(record, %{id: "user-1"})
    assert {:ok, payload} = PreviewReference.verify(token, %{id: "user-1"})

    assert payload["filename"] == "generated.txt"
    assert payload["source"] == "generated.txt"
  end

  test "uses generic filename and nil identity for unsupported user shape" do
    record = %Record{
      id: nil,
      kind: :file,
      path: nil,
      name: nil,
      attributes: nil,
      materialization_handle: "handle-1"
    }

    token = PreviewReference.sign_record(record, %{username: "anonymous"})
    assert {:ok, payload} = PreviewReference.verify(token, %{username: "anonymous"})

    assert payload["filename"] == "file"
    assert payload["source"] == nil
    assert payload["user_id"] == nil
  end

  test "verify/2 rejects non-binary token" do
    assert PreviewReference.verify(nil, %{id: "user-1"}) ==
             {:error, :invalid_preview_reference}
  end
end
