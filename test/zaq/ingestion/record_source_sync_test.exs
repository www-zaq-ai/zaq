defmodule Zaq.Ingestion.RecordSourceSyncTest do
  use Zaq.DataCase, async: false

  import Mox

  alias Zaq.Contracts.Record
  alias Zaq.Ingestion.RecordSource

  setup :verify_on_exit!

  test "materialize/1 returns temporary markdown write errors unchanged" do
    error_tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "record_source_write_error_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(error_tmp_dir)
    File.write!(Path.join(error_tmp_dir, "zaq_temporary_materializations"), "not a directory")

    previous_tmpdir = System.get_env("TMPDIR")
    System.put_env("TMPDIR", error_tmp_dir)

    on_exit(fn ->
      if previous_tmpdir,
        do: System.put_env("TMPDIR", previous_tmpdir),
        else: System.delete_env("TMPDIR")

      File.rm_rf!(error_tmp_dir)
    end)

    downloaded = %Record{id: "markdown", kind: :file, content: "markdown"}

    expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event ->
      %{event | response: {:ok, %{record: downloaded}}}
    end)

    record = %Record{
      id: "file-1",
      kind: :file,
      name: "Report.pdf",
      mime_type: "application/pdf",
      url: "https://drive.example/report",
      attributes: %{
        "provider" => "google_drive",
        "config_id" => "cfg-1",
        "provider_record_id" => "provider-file-1"
      }
    }

    context = %{node_router: Zaq.NodeRouterMock}

    assert RecordSource.materialize(record, context) == {:error, :enotdir}
  end
end
