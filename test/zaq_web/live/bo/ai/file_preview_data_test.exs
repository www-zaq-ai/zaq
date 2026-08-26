defmodule ZaqWeb.Live.BO.AI.FilePreviewDataTest do
  use Zaq.DataCase, async: false

  setup :verify_on_exit!

  alias Zaq.Channels.Materializers.DataSourceDocument
  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.Ingestion.Document
  alias Zaq.Repo
  alias ZaqWeb.Live.BO.AI.FilePreviewData

  setup do
    user = super_admin_fixture() |> Repo.preload(:role)
    root = Path.join(System.tmp_dir!(), "zaq_file_preview_#{System.unique_integer([:positive])}")
    scripts = Path.join(root, "scripts")
    File.mkdir_p!(scripts)

    old_ingestion = Application.get_env(:zaq, Zaq.Ingestion)
    old_runner = Application.get_env(:zaq, Zaq.Ingestion.Python.Runner)
    Application.put_env(:zaq, Zaq.Ingestion, base_path: root)

    on_exit(fn ->
      restore_env(:zaq, Zaq.Ingestion, old_ingestion)
      restore_env(:zaq, Zaq.Ingestion.Python.Runner, old_runner)
      File.rm_rf!(root)
    end)

    {:ok, user: user, root: root, scripts: scripts}
  end

  test "previewable_path?/1 rejects non-binary paths" do
    for path <- [nil, :file, 1, [], %{}], do: refute(FilePreviewData.previewable_path?(path))
  end

  test "invalid signed handle is unavailable", %{user: user} do
    record = %Record{
      id: "notes.txt",
      kind: :file,
      name: "notes.txt",
      path: "notes.txt",
      materialization_handle: "invalid-handle"
    }

    assert {:ok, preview} = FilePreviewData.load(record, user)
    assert unavailable(preview, "notes.txt", ".txt")
  end

  test "an unmaterialized record without content is unavailable", %{user: user} do
    record = %Record{id: "notes.txt", kind: :file, name: "notes.txt", path: "notes.txt"}
    assert {:ok, preview} = FilePreviewData.load(record, user)
    assert unavailable(preview, "notes.txt", ".txt")
  end

  test "inline records use the appropriate preview kind", %{user: user} do
    now = ~U[2024-01-02 03:04:05Z]

    cases = [
      {"plain.txt", "hello", %{}, :text, "hello", nil},
      {"broken.txt", "not base64", %{"encoding" => "base64"}, :binary, nil, nil},
      {"value.txt", 123, %{}, :binary, nil, nil},
      {"photo.png", "bytes", %{}, :image, nil, nil},
      {"report.pdf", "bytes", %{}, :pdf, nil, nil},
      {"data.bin", "bytes", %{}, :binary, nil, nil}
    ]

    for {name, content, attrs, kind, expected_content, html} <- cases do
      record = %Record{
        id: name,
        kind: :file,
        name: name,
        path: name,
        content: content,
        attributes: attrs,
        size: 7,
        modified_at: now
      }

      if kind == :binary and attrs == %{"encoding" => "base64"} do
        assert_raise CaseClauseError, fn -> FilePreviewData.load(record, user) end
      else
        assert {:ok, preview} = FilePreviewData.load(record, user)
        assert preview.relative_path == name
        assert preview.filename == name
        assert preview.ext == Path.extname(name)
        assert preview.kind == kind
        assert preview.content == expected_content
        assert preview.rendered_html == html
        assert preview.file_size == 7
        assert preview.modified_at == now
        assert preview.raw_url == nil
      end
    end
  end

  test "persisted external Document materializes and previews with provider metadata", %{
    user: user
  } do
    {:ok, handle} = DataSourceDocument.issue("drive", "file-1", %{"config_id" => "cfg"})
    updated_at = ~U[2024-02-03 04:05:06Z]

    {:ok, doc} =
      Document.create(%{
        source: "data_source/drive/cfg/file-1",
        title: "ignored title",
        metadata: %{
          "materialization_handle" => handle,
          "provider" => "drive",
          "provider_config_id" => "cfg",
          "provider_file_id" => "file-1",
          "provider_name" => "Quarterly.txt",
          "provider_mime_type" => "text/plain",
          "provider_size" => 13
        }
      })

    doc = Repo.update!(Ecto.Changeset.change(doc, updated_at: updated_at))

    requested = %Record{
      id: "file-1",
      kind: :file,
      name: "Quarterly.txt",
      content: Base.encode64("quarterly data"),
      attributes: %{"encoding" => "base64"}
    }

    expect_materialization(handle, requested)

    assert {:ok, preview} =
             FilePreviewData.load(doc.source, user, node_router: Zaq.NodeRouterMock)

    assert preview.relative_path == doc.source
    assert preview.filename == "Quarterly.txt"
    assert preview.ext == ".txt"
    assert preview.content == "quarterly data"
    assert preview.kind == :text
    assert preview.file_size == 13
    assert preview.modified_at == updated_at
    assert preview.raw_url =~ "/bo/files/ref/"
  end

  test "source, filename, and raw URL fallbacks are canonical", %{user: user} do
    external = fn attrs ->
      %Record{id: "provider-id", kind: :file, content: "x", attributes: attrs}
    end

    assert {:ok, one} =
             FilePreviewData.load(
               external.(%{
                 "provider" => "drive",
                 "config_id" => "c",
                 "provider_record_id" => "f"
               }),
               user
             )

    assert one.relative_path == "data_source/drive/c/f"
    assert one.filename == "provider-id"
    assert one.raw_url == nil

    assert {:ok, two} =
             FilePreviewData.load(
               %Record{id: "id", kind: :file, path: "/a/b/report.txt", content: "x"},
               user
             )

    assert two.relative_path == "/a/b/report.txt"
    assert two.filename == "report.txt"

    assert {:ok, three} =
             FilePreviewData.load(
               %Record{
                 id: "folder/id.txt",
                 kind: :file,
                 content: "x",
                 attributes: %{"source" => "local.txt"}
               },
               user
             )

    assert three.relative_path == "local.txt"
    assert three.filename == "id.txt"

    assert {:ok, four} =
             FilePreviewData.load(
               %Record{
                 id: nil,
                 kind: :file,
                 content: "x",
                 attributes: %{"source" => "source.bin"}
               },
               user
             )

    assert four.filename == "file"
    assert four.raw_url == nil
  end

  test "legacy directories return a complete not found preview", %{root: root} do
    File.mkdir_p!(Path.join(root, "archive"))
    assert {:ok, preview} = FilePreviewData.load("archive", super_admin_fixture())

    assert preview == %{
             relative_path: "archive",
             filename: "archive",
             ext: "",
             kind: :not_found,
             content: nil,
             rendered_html: nil,
             file_size: nil,
             modified_at: nil,
             raw_url: nil
           }
  end

  test "unreadable markdown and text files return error previews", %{root: root, user: user} do
    for name <- ["bad.md", "bad.txt"] do
      path = Path.join(root, name)
      File.write!(path, "secret")
      File.chmod!(path, 0o000)
      on_exit(fn -> if File.exists?(path), do: File.chmod!(path, 0o644) end)
      assert {:ok, preview} = FilePreviewData.load(name, user)
      assert preview.kind == :error
      assert preview.content == nil
    end
  end

  test "inline DOCX conversion sanitizes and cleans up temporary files", %{
    user: user,
    scripts: scripts
  } do
    install_converter(scripts, "docx_to_md.py")
    record = %Record{id: "unsafe name", kind: :file, name: "../unsafe name.docx", content: "docx"}
    assert {:ok, preview} = FilePreviewData.load(record, user)
    assert preview.kind == :markdown
    assert preview.content =~ "unsafe_name-"
    assert preview.rendered_html =~ "unsafe_name-"

    refute Enum.any?(
             Path.wildcard(Path.join(System.tmp_dir!(), "unsafe_name-*.docx")),
             &File.exists?/1
           )

    refute Enum.any?(
             Path.wildcard(Path.join(System.tmp_dir!(), "unsafe_name-*.md")),
             &File.exists?/1
           )
  end

  test "inline XLSX conversion sanitizes and cleans up temporary files", %{
    user: user,
    scripts: scripts
  } do
    install_converter(scripts, "xlsx_to_md.py")

    record = %Record{
      id: "unsafe sheet",
      kind: :file,
      name: "../unsafe sheet.xlsx",
      content: "xlsx"
    }

    assert {:ok, preview} = FilePreviewData.load(record, user)
    assert preview.kind == :markdown
    assert preview.content =~ "unsafe_sheet-"
    assert preview.rendered_html =~ "unsafe_sheet-"

    refute Enum.any?(
             Path.wildcard(Path.join(System.tmp_dir!(), "unsafe_sheet-*.xlsx")),
             &File.exists?/1
           )

    refute Enum.any?(
             Path.wildcard(Path.join(System.tmp_dir!(), "unsafe_sheet-*.md")),
             &File.exists?/1
           )
  end

  defp unavailable(preview, source, extension) do
    preview == %{
      relative_path: source,
      filename: Path.basename(source),
      ext: extension,
      kind: :binary,
      content: nil,
      rendered_html: nil,
      file_size: nil,
      modified_at: nil,
      raw_url: nil
    }
  end

  defp expect_materialization(handle, requested) do
    expect(Zaq.NodeRouterMock, :dispatch, fn %Event{
                                               request: %{provider: "drive", params: params},
                                               next_hop: %{destination: :channels},
                                               opts: opts
                                             } = event ->
      assert params["file_id"] == "file-1"
      assert opts[:action] == :data_source_download_document
      %{event | response: {:ok, %{record: requested}}}
    end)

    _ = handle
  end

  defp install_converter(scripts, name) do
    script =
      "import os,sys\noutput=sys.argv[sys.argv.index('--output')+1]\nsource=sys.argv[1]\nopen(output,'w').write('converted '+os.path.basename(source))\n"

    File.write!(Path.join(scripts, name), script)
    old = Application.get_env(:zaq, Zaq.Ingestion.Python.Runner)
    Application.put_env(:zaq, Zaq.Ingestion.Python.Runner, scripts_dir: scripts)
    on_exit(fn -> restore_env(:zaq, Zaq.Ingestion.Python.Runner, old) end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
