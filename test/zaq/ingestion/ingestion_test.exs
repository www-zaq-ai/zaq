defmodule Zaq.IngestionTest do
  # async: false — tests override Application env via put_env; concurrent runs cause flaky reads.
  use Zaq.DataCase, async: false

  import Mox

  alias Zaq.Accounts.People
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Event
  alias Zaq.Ingestion
  alias Zaq.Ingestion.Api
  alias Zaq.Permissions

  alias Zaq.Ingestion.{
    Chunk,
    Document,
    DocumentAccess,
    DocumentChunker,
    IngestChunkJob,
    IngestJob,
    IngestWorker,
    RecordSource
  }

  alias Zaq.Repo
  alias Zaq.SystemConfigFixtures

  defmodule ExternalDataSourceBridgeStub do
    def download_document(provider, params, _context) do
      send(self(), {:download_document, provider, params})

      if params["file_id"] == "pdf-123" do
        {:ok,
         %{
           record: %Record{
             id: params["file_id"],
             kind: :file,
             name: "External Deck.pdf",
             mime_type: "application/pdf",
             content: Base.encode64("pdf bytes"),
             attributes: %{"encoding" => "base64"}
           }
         }}
      else
        {:ok,
         %{
           record: %Record{
             id: params["file_id"],
             kind: :file,
             name: "External Doc.md",
             mime_type: "text/markdown",
             content: "# External Doc\n\nGenerated markdown",
             attributes: %{"encoding" => "utf-8"}
           }
         }}
      end
    end
  end

  defmodule ExternalPdfPipelineStub do
    def run(pdf_path, _opts \\ []) do
      md_path = Path.rootname(pdf_path) <> ".md"
      File.write!(md_path, "# External Deck\n\nGenerated PDF markdown")
      {:ok, md_path}
    end
  end

  setup do
    SystemConfigFixtures.seed_embedding_config(%{model: "test-model", dimension: "1536"})
    stub_embedding_success()
    Mox.set_mox_global()
    :ok
  end

  setup :verify_on_exit!

  defp create_job(attrs \\ %{}) do
    %IngestJob{}
    |> IngestJob.changeset(
      Map.merge(%{file_path: "docs/test.md", status: "pending", mode: "async"}, attrs)
    )
    |> Repo.insert!()
  end

  defp restore_ingestion_env(nil), do: Application.delete_env(:zaq, Zaq.Ingestion)
  defp restore_ingestion_env(original), do: Application.put_env(:zaq, Zaq.Ingestion, original)

  defp stub_embedding_success do
    Req.Test.stub(Zaq.Embedding.Client, fn conn ->
      body = Jason.encode!(%{"data" => [%{"embedding" => List.duplicate(0.1, 1536)}]})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp create_document_with_chunks(source, chunk_count),
    do: create_document_with_chunks(source, chunk_count, %{})

  defp create_document_with_chunks(source, chunk_count, metadata) do
    {:ok, document} =
      Document.create(%{
        source: source,
        content: "content for #{source}",
        metadata: metadata
      })

    if chunk_count > 0 do
      Enum.each(1..chunk_count, fn chunk_index ->
        %Chunk{}
        |> Chunk.changeset(%{
          document_id: document.id,
          content: "chunk #{chunk_index} for #{source}",
          chunk_index: chunk_index
        })
        |> Repo.insert!()
      end)
    end

    document
  end

  defp signed_record(%Record{} = record) do
    permissions =
      case record.permissions do
        permissions when is_list(permissions) -> Enum.map(permissions, &signed_record/1)
        other -> other
      end

    record = %{record | permissions: permissions}
    {:ok, signed} = Provenance.seal(record, provenance_claims(record))
    signed
  end

  defp provenance_claims(%Record{attributes: attrs}) when is_map(attrs) do
    %{
      "provider" => Map.get(attrs, "provider") || Map.get(attrs, :provider),
      "config_id" => Map.get(attrs, "config_id") || Map.get(attrs, :config_id)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  test "mark_watch_active stores watched status without provider runtime metadata" do
    source = "data_source/google_drive/1/file-1"
    create_document_with_chunks(source, 0, %{"existing" => true})

    assert {:ok, doc} =
             Ingestion.mark_watch_active(
               %{source: source, kind: :file},
               %{
                 metadata: %{
                   "watch" => %{
                     "channel_id" => "channel-1",
                     "resource_id" => "resource-1"
                   }
                 }
               }
             )

    assert doc.watch_status == "watched"
    assert doc.watch_error == nil
    assert doc.metadata["existing"] == true
    refute Map.has_key?(doc.metadata, "watch")
  end

  test "mark_watch_error records provider setup failures" do
    source = "data_source/google_drive/1/file-error"
    create_document_with_chunks(source, 0)

    assert {:ok, doc} = Ingestion.mark_watch_error(%{source: source}, :unsupported)

    assert doc.watch_status == "error"
    assert doc.watch_error == ":unsupported"
  end

  test "process_data_source_changes rejects invalid requests" do
    assert {:error, :invalid_request} = Ingestion.process_data_source_changes(nil)
    assert {:error, :invalid_request} = Ingestion.process_data_source_changes([])
  end

  test "watch helpers return neutral values for invalid inputs" do
    assert Ingestion.count_watched_provider_documents(nil, nil) == 0
    assert Ingestion.count_watched_provider_documents("google_drive", nil) == 0
    assert Ingestion.data_source_inherited_watch(nil, nil, nil) == nil
    assert Ingestion.data_source_inherited_watch("google_drive", nil, nil) == nil

    assert Ingestion.data_source_record_watch_active?(nil) == false
    assert Ingestion.data_source_record_watch_active?(%{}) == false
    assert Ingestion.data_source_record_watch_active?(%{watch_status: "unwatched"}) == false
  end

  test "mark_watch_active inserts a watched folder target when the document is missing" do
    source = "data_source/google_drive/42/folder-#{System.unique_integer([:positive])}"

    assert {:ok, doc} = Ingestion.mark_watch_active(%{source: source, kind: :folder}, %{})
    assert doc.source == source
    assert doc.content == nil
    assert doc.metadata["entry_type"] == "folder"
    assert doc.watch_status == "watched"
  end

  test "mark_watch_active and mark_watch_error skip invalid targets" do
    assert :skip = Ingestion.mark_watch_active(%{}, %{})
    assert :skip = Ingestion.mark_watch_active(%{source: nil}, %{})
    assert :skip = Ingestion.mark_watch_error(%{}, :unsupported)
    assert :skip = Ingestion.mark_watch_error(%{source: nil}, :unsupported)
  end

  test "mark_watch_error skips missing documents" do
    source = "data_source/google_drive/42/missing-#{System.unique_integer([:positive])}"

    assert :skip = Ingestion.mark_watch_error(%{source: source}, :unsupported)
    assert Document.get_by_source(source) == nil
  end

  test "request_watch skips invalid targets and preserves existing metadata" do
    source = "data_source/google_drive/42/watch-#{System.unique_integer([:positive])}"
    {:ok, _doc} = Document.create(%{source: source, metadata: %{"existing" => true}})

    assert %{updated: 0, skipped: 2} =
             Ingestion.request_watch([
               %{},
               %{source: "data_source/google_drive/42/missing", kind: :file}
             ])

    assert %{updated: 1, skipped: 0} = Ingestion.request_watch([%{source: source, kind: :file}])

    reloaded = Document.get_by_source(source)
    assert reloaded.watch_status == "pending"
    assert reloaded.metadata["existing"] == true
  end

  test "process_data_source_changes normalizes mixed record shapes without enqueuing jobs" do
    request = %{
      provider: nil,
      config_id: nil,
      records: [
        %Record{id: "struct-record", kind: :file, name: "Struct.md"},
        %{id: "map-record", kind: :file},
        %{kind: :file}
      ],
      signals: [
        %{
          record: %Record{id: "deleted-record", kind: :file, name: "Deleted.md"},
          change_type: "deleted"
        },
        %{
          record: %Record{id: "atom-record", kind: :file, name: "Atom.md"},
          change_type: :updated
        },
        %{provider_record_id: "fallback-record", record: %{kind: :file}, change_type: "updated"},
        %{record: nil, change_type: "updated"},
        %{
          record: %Record{id: "bad-atom-record", kind: :file, name: "Bad.md"},
          change_type: "not_an_atom"
        }
      ]
    }

    assert {:ok, %{jobs: [], removed: 0}} = Ingestion.process_data_source_changes(request)
  end

  test "process_data_source_changes deletes watched children and ignores missing parents" do
    parent_source = "data_source/google_drive/42/fallback-parent"
    child_id = "child-#{System.unique_integer([:positive])}"
    child_source = "data_source/google_drive/42/#{child_id}"

    {:ok, _parent_doc} =
      Document.insert_new(%{
        source: parent_source,
        metadata: %{"entry_type" => "folder"},
        watch_status: "watched"
      })

    {:ok, child_doc} = Document.insert_new(%{source: child_source, watch_status: "watched"})

    request = %{
      provider: "google_drive",
      config_id: 42,
      signals: [
        %{
          provider_record_id: child_id,
          removed: true,
          record: %{id: child_id, parents: ["fallback-parent"]}
        },
        %{
          provider_record_id: "missing-1",
          removed: true,
          record: %{id: "missing-1", parents: ["fallback-parent", "", nil]}
        }
      ]
    }

    assert {:ok, %{jobs: [], removed: 1}} = Ingestion.process_data_source_changes(request)
    assert Document.get(child_doc.id) == nil
  end

  test "process_data_source_changes stringifies atom and integer request identifiers" do
    source_id = "123"
    source = "data_source/google_drive/42/#{source_id}"

    {:ok, _doc} = Document.insert_new(%{source: source, watch_status: "watched"})

    request = %{
      provider: :google_drive,
      config_id: 42,
      signals: [
        %{
          provider_record_id: "123",
          change_type: :updated,
          record: %{name: "Integer.md", mime_type: "text/markdown"}
        }
      ]
    }

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, %{jobs: [], removed: 0}} = Ingestion.process_data_source_changes(request)
    end)
  end

  test "process_data_source_changes builds removed records from provider_record_id only" do
    source_id = "remove-fallback-#{System.unique_integer([:positive])}"
    source = "data_source/google_drive/42/#{source_id}"

    {:ok, source_doc} = Document.insert_new(%{source: source, watch_status: "watched"})

    request = %{
      provider: "google_drive",
      config_id: 42,
      signals: [%{provider_record_id: source_id, removed: true}]
    }

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, %{jobs: [], removed: 1}} = Ingestion.process_data_source_changes(request)
    end)

    assert Document.get(source_doc.id) == nil
  end

  describe "external data-source record ingestion" do
    setup do
      original_ingestion = Application.get_env(:zaq, Zaq.Ingestion)
      original_bridge = Application.get_env(:zaq, :ingestion_data_source_bridge_module)
      original_processor = Application.get_env(:zaq, :document_processor)
      original_pdf_pipeline = Application.get_env(:zaq, :pdf_pipeline_module)

      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "zaq_external_ingestion_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)

      Application.put_env(:zaq, Zaq.Ingestion, base_path: tmp_dir)
      Application.put_env(:zaq, :document_processor, Zaq.Ingestion.DocumentProcessor)

      Application.put_env(
        :zaq,
        :ingestion_data_source_bridge_module,
        ExternalDataSourceBridgeStub
      )

      on_exit(fn ->
        restore_ingestion_env(original_ingestion)

        case original_bridge do
          nil -> Application.delete_env(:zaq, :ingestion_data_source_bridge_module)
          module -> Application.put_env(:zaq, :ingestion_data_source_bridge_module, module)
        end

        case original_processor do
          nil -> Application.delete_env(:zaq, :document_processor)
          module -> Application.put_env(:zaq, :document_processor, module)
        end

        case original_pdf_pipeline do
          nil -> Application.delete_env(:zaq, :pdf_pipeline_module)
          module -> Application.put_env(:zaq, :pdf_pipeline_module, module)
        end

        File.rm_rf!(tmp_dir)
      end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "stores converted content on the canonical source and imports permissions" do
      record =
        %Record{
          id: "file-123",
          kind: :file,
          name: "External Doc",
          url: "https://drive.example/file-123",
          mime_type: "application/vnd.google-apps.document",
          parent_id: "folder-123",
          parent_ids: ["folder-123"],
          owners: [%{"email" => "owner@example.com", "display_name" => "Owner Person"}],
          permissions: [
            %Record{
              id: "perm-reader",
              kind: :permission,
              name: "Reader Person",
              attributes: %{
                "email" => "reader@example.com",
                "principal_key" => "reader@example.com",
                "role" => "reader"
              },
              raw: %{"emailAddress" => "reader@example.com", "role" => "reader"}
            },
            %Record{
              id: "perm-writer",
              kind: :permission,
              name: "Writer Person",
              attributes: %{
                "email" => "writer@example.com",
                "principal_key" => "writer@example.com",
                "role" => "writer"
              },
              raw: %{"emailAddress" => "writer@example.com", "role" => "writer"}
            }
          ],
          attributes: %{
            "provider" => "google_drive",
            "config_id" => 42,
            "provider_record_id" => "file-123"
          },
          content: "must not be stored",
          raw: %{"content" => "must not be stored"}
        }
        |> signed_record()

      job =
        Oban.Testing.with_testing_mode(:manual, fn ->
          assert {:ok, [job]} = Ingestion.ingest_records([record], %{mode: "async"})
          assert :ok = IngestWorker.perform(%Oban.Job{args: %{"job_id" => job.id}})
          Repo.get!(IngestJob, job.id)
        end)

      assert_received {:download_document, "google_drive",
                       %{
                         "config_id" => "42",
                         "file_id" => "file-123",
                         "document_mime_type" => "application/vnd.google-apps.document"
                       }}

      source = "data_source/google_drive/42/file-123"

      assert %Document{} = source_doc = Document.get_by_source(source)
      refute Document.get_by_source(source <> ".md")
      assert source_doc.title == "External Doc"
      assert source_doc.content =~ "Generated markdown"
      assert source_doc.metadata["provider_url"] == "https://drive.example/file-123"
      assert source_doc.metadata["provider_parent_id"] == "folder-123"
      assert source_doc.metadata["provider_parent_ids"] == ["folder-123"]

      assert Repo.get!(IngestJob, job.id).document_id == source_doc.id

      assert Repo.aggregate(from(c in IngestChunkJob, where: c.ingest_job_id == ^job.id), :count) >
               0

      stored_record = Repo.get!(IngestJob, job.id).source_record
      refute Map.has_key?(stored_record, "content")
      refute Map.has_key?(stored_record, "raw")

      source_perms = Ingestion.list_document_permissions(source_doc.id)

      assert permission_rights(source_perms, "owner@example.com") == ["read", "write"]
      assert permission_rights(source_perms, "reader@example.com") == ["read"]
      assert permission_rights(source_perms, "writer@example.com") == ["read", "write"]
    end

    test "base64 external originals use job-scoped temporary artifacts" do
      record =
        %Record{
          id: "pdf-123",
          kind: :file,
          name: "External Deck.pdf",
          attributes: %{
            "provider" => "google_drive",
            "config_id" => 42,
            "provider_record_id" => "pdf-123"
          }
        }
        |> signed_record()
        |> signed_record()
        |> signed_record()

      assert {:ok, materialized} = RecordSource.materialize(record)
      assert String.ends_with?(materialized.path, ".pdf")
      assert [cleanup_path] = materialized.cleanup_paths
      assert cleanup_path == Path.dirname(materialized.path)
    end

    test "process_data_source_changes only enqueues watched records and watched folder children" do
      {:ok, _folder_doc} =
        Document.insert_new(%{
          source: "data_source/google_drive/42/folder-1",
          metadata: %{"entry_type" => "folder"},
          watch_status: "watched"
        })

      {:ok, _file_doc} =
        Document.insert_new(%{
          source: "data_source/google_drive/42/direct-1",
          content: "old content",
          watch_status: "watched"
        })

      request = %{
        provider: "google_drive",
        config_id: 42,
        signals: [
          %{
            provider_record_id: "direct-1",
            change_type: :updated,
            record: %{id: "direct-1", name: "Direct.md", mime_type: "text/markdown"}
          },
          %{
            provider_record_id: "child-1",
            change_type: :updated,
            record: %{
              id: "child-1",
              name: "Child.md",
              mime_type: "text/markdown",
              parents: ["folder-1"]
            }
          },
          %{
            provider_record_id: "other-1",
            change_type: :updated,
            record: %{id: "other-1", name: "Other.md", mime_type: "text/markdown"}
          }
        ]
      }

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{jobs: jobs, removed: 0}} = Ingestion.process_data_source_changes(request)
        assert Enum.map(jobs, & &1.source_record["id"]) |> Enum.sort() == ["child-1", "direct-1"]
      end)
    end

    test "process_data_source_changes deletes removed watched-folder children from persisted parent metadata" do
      {:ok, _folder_doc} =
        Document.insert_new(%{
          source: "data_source/google_drive/42/folder-1",
          metadata: %{"entry_type" => "folder"},
          watch_status: "watched"
        })

      source = "data_source/google_drive/42/child-1"

      source_doc =
        create_document_with_chunks(source, 2, %{
          "provider_parent_ids" => ["folder-1"]
        })

      request = %{
        provider: "google_drive",
        config_id: 42,
        signals: [%{provider_record_id: "child-1", removed: true}]
      }

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{jobs: [], removed: 1}} = Ingestion.process_data_source_changes(request)
      end)

      assert Document.get(source_doc.id) == nil
      assert Chunk.count_by_document(source_doc.id) == 0
    end

    test "process_data_source_changes treats removed? tombstones as deletions without reingestion" do
      source = "data_source/google_drive/42/direct-removed"
      doc = create_document_with_chunks(source, 1, %{})

      {:ok, doc} = doc |> Document.changeset(%{watch_status: "watched"}) |> Repo.update()

      request = %{
        provider: "google_drive",
        config_id: 42,
        signals: [%{provider_record_id: "direct-removed", removed?: true}]
      }

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{jobs: [], removed: 1}} = Ingestion.process_data_source_changes(request)
      end)

      assert Document.get(doc.id) == nil
      assert Chunk.count_by_document(doc.id) == 0
    end

    test "process_data_source_changes ignores removed unwatched data-source records" do
      source = "data_source/google_drive/42/unwatched-removed"
      doc = create_document_with_chunks(source, 1, %{})

      request = %{
        provider: "google_drive",
        config_id: 42,
        signals: [%{provider_record_id: "unwatched-removed", deleted: true}]
      }

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{jobs: [], removed: 0}} = Ingestion.process_data_source_changes(request)
      end)

      assert Document.get(doc.id)
      assert Chunk.count_by_document(doc.id) == 1
    end

    test "base64 external PDFs store canonical data-source document rows" do
      Application.put_env(:zaq, :pdf_pipeline_module, ExternalPdfPipelineStub)

      record =
        %Record{
          id: "pdf-123",
          kind: :file,
          name: "External Deck.pdf",
          url: "https://drive.example/pdf-123",
          mime_type: "application/pdf",
          attributes: %{
            "provider" => "google_drive",
            "config_id" => 42,
            "provider_record_id" => "pdf-123"
          }
        }
        |> signed_record()

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, [job]} = Ingestion.ingest_records([record], %{mode: "async"})
        assert :ok = IngestWorker.perform(%Oban.Job{args: %{"job_id" => job.id}})
      end)

      source = "data_source/google_drive/42/pdf-123"

      assert %Document{} = source_doc = Document.get_by_source(source)
      refute Document.get_by_source(source <> ".md")
      assert source_doc.title == "External Deck.pdf"
      assert source_doc.content =~ "Generated PDF markdown"
      assert source_doc.metadata["provider_url"] == "https://drive.example/pdf-123"

      refute Repo.exists?(
               from d in Document, where: like(d.source, "%temporary_materializations%")
             )
    end
  end

  defp permission_rights(permissions, email) do
    permissions
    |> Enum.find(fn permission -> permission.person && permission.person.email == email end)
    |> then(fn permission -> if permission, do: permission.access_rights, else: nil end)
  end

  defmodule RetryChunkProcessor do
    alias Zaq.Ingestion.Chunk
    alias Zaq.Ingestion.DocumentChunker

    def store_chunk_with_metadata(
          %DocumentChunker.Chunk{} = chunk,
          document_id,
          chunk_index
        ) do
      Chunk.create(%{
        document_id: document_id,
        content: chunk.content,
        chunk_index: chunk_index
      })
    end
  end

  describe "ingest_records/2" do
    test "ingestion api accepts record dispatch events" do
      event =
        Event.new(%{records: [], params: %{"mode" => "async"}}, :ingestion,
          opts: [action: :ingest_records]
        )

      assert %{response: {:ok, []}} = Api.handle_event(event, :ingest_records, nil)
    end
  end

  describe "list_document_sources/1" do
    test "returns a list when called with nil (all sources)" do
      create_doc_with_source("ls-nil/some-doc.md")
      result = Ingestion.list_document_sources(nil)
      assert is_list(result)
    end

    test "returns a list when called with empty string (all sources)" do
      create_doc_with_source("ls-empty/some-doc.md")
      result = Ingestion.list_document_sources("")
      assert is_list(result)
    end

    test "returns name-filtered results for a simple name query" do
      unique = System.unique_integer([:positive])
      create_doc_with_source("ls-name-#{unique}/doc.md")
      result = Ingestion.list_document_sources("ls-name-#{unique}")
      assert is_list(result)
      labels = Enum.map(result, & &1.label)
      assert Enum.any?(labels, &String.contains?(&1, "ls-name-#{unique}"))
    end

    test "returns browse results for a folder/child query" do
      unique = System.unique_integer([:positive])
      create_doc_with_source("ls-browse-#{unique}/subfolder/doc.md")
      result = Ingestion.list_document_sources("ls-browse-#{unique}/")
      assert is_list(result)
    end
  end

  describe "list_jobs/1" do
    test "returns all jobs ordered by inserted_at desc" do
      j1 = create_job(%{file_path: "a.md"})
      j2 = create_job(%{file_path: "b.md"})

      jobs = Ingestion.list_jobs()
      ids = Enum.map(jobs, & &1.id)

      assert j2.id in ids
      assert j1.id in ids
    end

    test "filters by status" do
      create_job(%{file_path: "a.md", status: "pending"})
      create_job(%{file_path: "b.md", status: "completed"})

      jobs = Ingestion.list_jobs(status: "pending")
      assert length(jobs) == 1
      assert hd(jobs).status == "pending"
    end

    test "filters by a list of statuses" do
      create_job(%{file_path: "a.md", status: "pending"})
      create_job(%{file_path: "b.md", status: "failed"})
      create_job(%{file_path: "c.md", status: "completed"})

      jobs = Ingestion.list_jobs(status: ["pending", "failed"])
      statuses = Enum.map(jobs, & &1.status)
      assert Enum.all?(statuses, &(&1 in ["pending", "failed"]))
      refute "completed" in statuses
    end

    test "paginates with page and per_page" do
      create_job(%{file_path: "one.md"})
      create_job(%{file_path: "two.md"})
      create_job(%{file_path: "three.md"})

      jobs = Ingestion.list_jobs(page: 2, per_page: 2)

      assert length(jobs) == 1
      assert hd(jobs).file_path == "one.md"
    end
  end

  describe "get_job/1" do
    test "returns job by id" do
      job = create_job()
      assert Ingestion.get_job(job.id).id == job.id
    end

    test "returns nil for unknown id" do
      assert Ingestion.get_job(Ecto.UUID.generate()) == nil
    end
  end

  describe "retry_job/1" do
    test "retries a failed job" do
      job = create_job(%{status: "failed", error: "something broke"})
      Ingestion.subscribe()

      expect(Zaq.DocumentProcessorMock, :process_single_file, fn _path, _opts ->
        {:ok, %{id: nil, chunks_count: 1, document_id: nil}}
      end)

      assert {:ok, retried} = Ingestion.retry_job(job.id)
      job_id = job.id
      assert retried.status == "pending"
      assert retried.error == nil
      assert_receive {:job_updated, %{id: ^job_id, status: "pending", error: nil}}
    end

    test "returns error if job is not failed" do
      job = create_job(%{status: "completed"})
      assert {:error, :not_failed} = Ingestion.retry_job(job.id)
    end

    test "retries a completed_with_errors job by enqueueing failed chunks only" do
      doc = create_document_with_chunks("retry-source.md", 0)

      job =
        create_job(%{
          status: "completed_with_errors",
          error: "2 chunks failed after retries",
          document_id: doc.id,
          failed_chunks: 2,
          failed_chunk_indices: [2, 5]
        })

      %IngestChunkJob{}
      |> IngestChunkJob.changeset(%{
        ingest_job_id: job.id,
        document_id: doc.id,
        chunk_index: 2,
        chunk_payload: %{"content" => "chunk two", "metadata" => %{}},
        status: "failed_final"
      })
      |> Repo.insert!()

      %IngestChunkJob{}
      |> IngestChunkJob.changeset(%{
        ingest_job_id: job.id,
        document_id: doc.id,
        chunk_index: 5,
        chunk_payload: %{"content" => "chunk five", "metadata" => %{}},
        status: "failed_final"
      })
      |> Repo.insert!()

      original_processor = Application.get_env(:zaq, :document_processor)

      on_exit(fn ->
        if is_nil(original_processor) do
          Application.delete_env(:zaq, :document_processor)
        else
          Application.put_env(:zaq, :document_processor, original_processor)
        end
      end)

      Application.put_env(:zaq, :document_processor, RetryChunkProcessor)

      assert {:ok, retried} = Ingestion.retry_job(job.id)
      assert retried.status == "pending"
      assert retried.error == nil

      updated = Repo.get!(IngestJob, job.id)
      assert updated.status in ["processing", "completed"]
      assert updated.failed_chunk_indices == []
    end

    test "returns error if job not found" do
      assert {:error, :not_found} = Ingestion.retry_job(Ecto.UUID.generate())
    end

    test "returns transition changeset errors while retrying failed jobs" do
      id = Ecto.UUID.generate()
      now = DateTime.utc_now()

      assert {1, nil} =
               Repo.insert_all(IngestJob, [
                 %{
                   id: id,
                   file_path: "",
                   status: "failed",
                   mode: "async",
                   inserted_at: now,
                   updated_at: now
                 }
               ])

      assert {:error, %Ecto.Changeset{} = changeset} = Ingestion.retry_job(id)
      assert "can't be blank" in errors_on(changeset).file_path
      assert Repo.get!(IngestJob, id).status == "failed"
    end
  end

  describe "cancel_job/1" do
    test "cancels a pending job" do
      job = create_job(%{status: "pending"})
      Ingestion.subscribe()

      assert {:ok, cancelled} = Ingestion.cancel_job(job.id)
      job_id = job.id
      assert cancelled.status == "failed"
      assert cancelled.error == "Cancelled by user."
      assert_receive {:job_updated, %{id: ^job_id, status: "failed", error: "Cancelled by user."}}
    end

    test "cancels a processing job" do
      job = create_job(%{status: "processing"})
      Ingestion.subscribe()

      assert {:ok, cancelled} = Ingestion.cancel_job(job.id)
      job_id = job.id
      assert cancelled.status == "failed"
      assert cancelled.error == "Cancelled by user."
      assert_receive {:job_updated, %{id: ^job_id, status: "failed", error: "Cancelled by user."}}
    end

    test "cancels pending Oban chunk workers for a processing job" do
      job = create_job(%{status: "processing"})

      {:ok, oban_job} =
        Repo.insert(%Oban.Job{
          queue: "ingestion_chunks",
          worker: "Zaq.Ingestion.IngestChunkWorker",
          args: %{"job_id" => job.id, "chunk_job_id" => Ecto.UUID.generate()},
          state: "available"
        })

      assert {:ok, _} = Ingestion.cancel_job(job.id)

      cancelled_oban_job = Repo.get(Oban.Job, oban_job.id)
      assert cancelled_oban_job.state == "cancelled"
    end

    test "terminates pending and processing IngestChunkJob rows on cancel" do
      job = create_job(%{status: "processing"})
      doc = create_document_with_chunks("cancel-test.md", 0)

      pending_chunk =
        %IngestChunkJob{}
        |> IngestChunkJob.changeset(%{
          ingest_job_id: job.id,
          document_id: doc.id,
          chunk_index: 1,
          chunk_payload: %{"content" => "chunk one", "metadata" => %{}},
          status: "pending"
        })
        |> Repo.insert!()

      processing_chunk =
        %IngestChunkJob{}
        |> IngestChunkJob.changeset(%{
          ingest_job_id: job.id,
          document_id: doc.id,
          chunk_index: 2,
          chunk_payload: %{"content" => "chunk two", "metadata" => %{}},
          status: "processing"
        })
        |> Repo.insert!()

      assert {:ok, _} = Ingestion.cancel_job(job.id)

      assert Repo.get!(IngestChunkJob, pending_chunk.id).status == "failed_final"
      assert Repo.get!(IngestChunkJob, processing_chunk.id).status == "failed_final"
    end

    test "returns error for completed or failed jobs" do
      completed_job = create_job(%{status: "completed"})
      failed_job = create_job(%{status: "failed"})

      assert {:error, :not_cancellable} = Ingestion.cancel_job(completed_job.id)
      assert {:error, :not_cancellable} = Ingestion.cancel_job(failed_job.id)
    end

    test "returns error if job not found" do
      assert {:error, :not_found} = Ingestion.cancel_job(Ecto.UUID.generate())
    end

    test "returns rollback changeset when cancellation transition fails" do
      id = Ecto.UUID.generate()
      now = DateTime.utc_now()

      assert {1, nil} =
               Repo.insert_all(IngestJob, [
                 %{
                   id: id,
                   file_path: "",
                   status: "processing",
                   mode: "async",
                   inserted_at: now,
                   updated_at: now
                 }
               ])

      assert {:error, %Ecto.Changeset{} = changeset} = Ingestion.cancel_job(id)
      assert "can't be blank" in errors_on(changeset).file_path
      assert Repo.get!(IngestJob, id).status == "processing"
    end
  end

  # ---------------------------------------------------------------------------
  # Permission helpers
  # ---------------------------------------------------------------------------

  defp create_person(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, person} =
      People.create_person(
        Map.merge(
          %{"full_name" => "Test Person #{unique}", "email" => "person#{unique}@test.com"},
          attrs
        )
      )

    person
  end

  defp create_team(attrs \\ %{}) do
    {:ok, team} =
      People.create_team(Map.merge(%{name: "Team #{System.unique_integer([:positive])}"}, attrs))

    team
  end

  defp create_doc_with_source(source) do
    {:ok, doc} = Document.create(%{source: source, content: "content"})
    doc
  end

  # ---------------------------------------------------------------------------
  # Permission schema (changeset tests live in permission_test.exs, but we
  # test the public Ingestion context functions here)
  # ---------------------------------------------------------------------------

  describe "set_document_permission/4 and list_document_permissions/1" do
    test "creates a person permission" do
      doc = create_doc_with_source("perm-test-person.md")
      person = create_person()

      assert {:ok, perm} = Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])
      assert perm.person_id == person.id
      assert perm.access_rights == ["read"]

      perms = Ingestion.list_document_permissions(doc.id)
      assert length(perms) == 1
      assert hd(perms).person_id == person.id
    end

    test "creates a team permission" do
      doc = create_doc_with_source("perm-test-team.md")
      team = create_team()

      assert {:ok, perm} = Ingestion.set_document_permission(doc.id, :team, team.id, ["read"])
      assert perm.team_id == team.id
    end

    test "upserts — updating existing permission changes access_rights" do
      doc = create_doc_with_source("perm-upsert.md")
      person = create_person()

      {:ok, _} = Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])

      {:ok, updated} =
        Ingestion.set_document_permission(doc.id, :person, person.id, ["read", "write"])

      assert updated.access_rights == ["read", "write"]
      assert length(Ingestion.list_document_permissions(doc.id)) == 1
    end

    test "counts document permissions for multiple documents" do
      doc1 = create_doc_with_source("perm-count-1.md")
      doc2 = create_doc_with_source("perm-count-2.md")
      doc3 = create_doc_with_source("perm-count-3.md")
      person = create_person()
      team = create_team()

      {:ok, _} = Ingestion.set_document_permission(doc1.id, :person, person.id, ["read"])
      {:ok, _} = Ingestion.set_document_permission(doc1.id, :team, team.id, ["read"])
      {:ok, _} = Ingestion.set_document_permission(doc2.id, :person, person.id, ["read"])

      assert Ingestion.count_document_permissions([doc1.id, doc2.id, doc3.id]) == %{
               to_string(doc1.id) => 2,
               to_string(doc2.id) => 1
             }
    end
  end

  describe "delete_document_permission/1" do
    test "deletes an existing permission" do
      doc = create_doc_with_source("del-perm.md")
      person = create_person()
      {:ok, perm} = Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])

      assert {:ok, _} = Ingestion.delete_document_permission(perm.id)
      assert Ingestion.list_document_permissions(doc.id) == []
    end

    test "returns error for missing permission" do
      assert {:error, :not_found} = Ingestion.delete_document_permission(-1)
    end
  end

  describe "list_person_permissions/1" do
    test "returns permissions for a given person across documents" do
      doc1 = create_doc_with_source("lpp-doc1.md")
      doc2 = create_doc_with_source("lpp-doc2.md")
      person = create_person()

      {:ok, _} = Ingestion.set_document_permission(doc1.id, :person, person.id, ["read"])
      {:ok, _} = Ingestion.set_document_permission(doc2.id, :person, person.id, ["read"])

      perms = Ingestion.list_person_permissions(person.id)
      assert length(perms) >= 2
      assert Enum.all?(perms, &(&1.person_id == person.id))
    end
  end

  describe "list_permitted_document_ids/3" do
    test "returns doc ids accessible by person" do
      doc = create_doc_with_source("permitted-person.md")
      person = create_person()
      {:ok, _} = Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])

      result = DocumentAccess.list_permitted_document_ids(person.id, [], [doc.id])
      assert doc.id in result
    end

    test "returns doc ids accessible by team" do
      doc = create_doc_with_source("permitted-team.md")
      team = create_team()
      person = create_person()
      {:ok, _} = Ingestion.set_document_permission(doc.id, :team, team.id, ["read"])

      result = DocumentAccess.list_permitted_document_ids(person.id, [team.id], [doc.id])
      assert doc.id in result
    end

    test "excludes doc ids without any matching permission" do
      doc = create_doc_with_source("not-permitted.md")
      person = create_person()

      result = DocumentAccess.list_permitted_document_ids(person.id, [], [doc.id])
      refute doc.id in result
    end

    test "returns empty list when person_id does not exist" do
      doc = create_doc_with_source("nonexistent-person.md")
      non_existing_person_id = -1

      result = DocumentAccess.list_permitted_document_ids(non_existing_person_id, [], [doc.id])
      assert result == []
    end

    test "returns empty list when team_ids don't match any permissions" do
      doc = create_doc_with_source("nonexistent-team.md")
      person = create_person()

      result = DocumentAccess.list_permitted_document_ids(person.id, [-1, -2], [doc.id])
      assert result == []
    end

    test "handles duplicate doc_ids in input without duplicating results" do
      doc = create_doc_with_source("dup-doc-ids.md")
      person = create_person()
      {:ok, _} = Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])

      result = DocumentAccess.list_permitted_document_ids(person.id, [], [doc.id, doc.id, doc.id])
      assert Enum.count(result, &(&1 == doc.id)) == 1
    end

    test "returns mixed results for docs with and without permissions" do
      permitted_doc = create_doc_with_source("mixed-permitted.md")
      denied_doc = create_doc_with_source("mixed-denied.md")
      person = create_person()
      other_person = create_person()
      {:ok, _} = Ingestion.set_document_permission(permitted_doc.id, :person, person.id, ["read"])

      {:ok, _} =
        Ingestion.set_document_permission(denied_doc.id, :person, other_person.id, ["read"])

      result =
        DocumentAccess.list_permitted_document_ids(person.id, [], [
          permitted_doc.id,
          denied_doc.id
        ])

      assert permitted_doc.id in result
      refute denied_doc.id in result
    end
  end

  describe "get_document_by_source!/1" do
    test "returns document when it exists" do
      doc = create_doc_with_source("get-doc-by-source.md")
      found = Ingestion.get_document_by_source!("get-doc-by-source.md")
      assert found.id == doc.id
    end

    test "raises when document not found" do
      assert_raise RuntimeError, fn ->
        Ingestion.get_document_by_source!("definitely-missing-#{System.unique_integer()}.md")
      end
    end
  end

  describe "list_documents_under_folder/2" do
    test "returns documents whose source starts with the given prefix" do
      folder = "vol/mydir"
      doc1 = create_doc_with_source("#{folder}/file1.md")
      doc2 = create_doc_with_source("#{folder}/nested/file2.md")
      _other = create_doc_with_source("other/file.md")

      results = Ingestion.list_documents_under_folder("vol", "mydir")
      ids = Enum.map(results, & &1.id)

      assert doc1.id in ids
      assert doc2.id in ids
    end
  end

  describe "list_folder_permissions/2" do
    test "returns unique permissions across all docs under a folder" do
      folder = "vol_fp/folder"
      doc1 = create_doc_with_source("#{folder}/a.md")
      doc2 = create_doc_with_source("#{folder}/b.md")
      person = create_person()

      {:ok, _} = Ingestion.set_document_permission(doc1.id, :person, person.id, ["read"])
      {:ok, _} = Ingestion.set_document_permission(doc2.id, :person, person.id, ["read"])

      perms = Ingestion.list_folder_permissions("vol_fp", "folder")
      person_perms = Enum.filter(perms, &(&1.person_id == person.id))
      assert length(person_perms) == 1
    end
  end

  describe "delete_folder_target_permission/3" do
    test "deletes all permissions for the same person across docs in folder" do
      folder = "vol_dfp/folder"
      doc1 = create_doc_with_source("#{folder}/a.md")
      doc2 = create_doc_with_source("#{folder}/b.md")
      person = create_person()

      {:ok, perm1} = Ingestion.set_document_permission(doc1.id, :person, person.id, ["read"])
      {:ok, _perm2} = Ingestion.set_document_permission(doc2.id, :person, person.id, ["read"])

      assert {:ok, 2} = Ingestion.delete_folder_target_permission("vol_dfp", "folder", perm1.id)
      assert Ingestion.list_document_permissions(doc1.id) == []
      assert Ingestion.list_document_permissions(doc2.id) == []
    end

    test "deletes all permissions for the same team across docs in folder" do
      folder = "vol_dfp_team/folder"
      doc1 = create_doc_with_source("#{folder}/a.md")
      doc2 = create_doc_with_source("#{folder}/b.md")
      team = create_team()

      {:ok, perm1} = Ingestion.set_document_permission(doc1.id, :team, team.id, ["read"])
      {:ok, _perm2} = Ingestion.set_document_permission(doc2.id, :team, team.id, ["read"])

      assert {:ok, 2} =
               Ingestion.delete_folder_target_permission("vol_dfp_team", "folder", perm1.id)

      assert Ingestion.list_document_permissions(doc1.id) == []
      assert Ingestion.list_document_permissions(doc2.id) == []
    end

    test "returns error when permission not found" do
      assert {:error, :not_found} =
               Ingestion.delete_folder_target_permission("vol", "folder", -1)
    end
  end

  describe "can_access_file?/2" do
    test "returns false when document has no permissions (private by default)" do
      source = "private-doc-#{System.unique_integer()}.md"
      _doc = create_doc_with_source(source)
      person = create_person()
      role = %Zaq.Accounts.Role{name: "staff"}
      user = %{role: role, person_id: person.id, team_ids: []}

      assert Ingestion.can_access_file?(source, user) == false
    end

    test "returns true when no document exists for the path" do
      person = create_person()
      role = %Zaq.Accounts.Role{name: "staff"}
      user = %{role: role, person_id: person.id, team_ids: []}

      assert Ingestion.can_access_file?("no-such-file-#{System.unique_integer()}.md", user) ==
               true
    end

    test "super_admin bypasses all permission checks" do
      source = "restricted-#{System.unique_integer()}.md"
      doc = create_doc_with_source(source)
      person = create_person()
      other_person = create_person()
      role = %Zaq.Accounts.Role{name: "super_admin"}
      user = %{role: role, person_id: other_person.id, team_ids: []}

      # Set a permission for a different person — super_admin still gets in
      {:ok, _} = Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])

      assert Ingestion.can_access_file?(source, user) == true
    end

    test "person with direct permission can access" do
      source = "restricted-person-#{System.unique_integer()}.md"
      doc = create_doc_with_source(source)
      person = create_person()
      role = %Zaq.Accounts.Role{name: "staff"}
      user = %{role: role, person_id: person.id, team_ids: []}

      {:ok, _} = Ingestion.set_document_permission(doc.id, :person, person.id, ["read"])

      assert Ingestion.can_access_file?(source, user) == true
    end

    test "person with team permission can access" do
      source = "restricted-team-#{System.unique_integer()}.md"
      doc = create_doc_with_source(source)
      person = create_person()
      team = create_team()
      role = %Zaq.Accounts.Role{name: "staff"}
      user = %{role: role, person_id: person.id, team_ids: [team.id]}

      {:ok, _} = Ingestion.set_document_permission(doc.id, :team, team.id, ["read"])

      assert Ingestion.can_access_file?(source, user) == true
    end

    test "person without any matching permission is denied" do
      source = "no-access-#{System.unique_integer()}.md"
      doc = create_doc_with_source(source)
      other_person = create_person()
      denied_person = create_person()
      role = %Zaq.Accounts.Role{name: "staff"}
      user = %{role: role, person_id: denied_person.id, team_ids: []}

      # Only other_person has permission
      {:ok, _} = Ingestion.set_document_permission(doc.id, :person, other_person.id, ["read"])

      assert Ingestion.can_access_file?(source, user) == false
    end
  end

  # ---------------------------------------------------------------------------
  # list_permitted_document_ids — public grants
  # ---------------------------------------------------------------------------

  describe "list_permitted_document_ids/3 — public grants" do
    test "returns public doc even when person has no permission row" do
      doc = create_doc_with_source("pub-tag-permitted-#{System.unique_integer()}.md")
      {:ok, _} = Permissions.grant_public(doc)
      person = create_person()

      result = DocumentAccess.list_permitted_document_ids(person.id, [], [doc.id])
      assert doc.id in result
    end

    test "non-public doc without permission row is excluded" do
      doc = create_doc_with_source("not-pub-#{System.unique_integer()}.md")
      person = create_person()

      result = DocumentAccess.list_permitted_document_ids(person.id, [], [doc.id])
      refute doc.id in result
    end

    test "public grant takes precedence regardless of team_ids" do
      doc = create_doc_with_source("pub-no-team-#{System.unique_integer()}.md")
      {:ok, _} = Permissions.grant_public(doc)
      person = create_person()

      result = DocumentAccess.list_permitted_document_ids(person.id, [-99], [doc.id])
      assert doc.id in result
    end
  end

  # ── Delete + list_document_sources integration ───────────────────────────────

  describe "list_document_sources/1 — nil and empty query" do
    test "returns sources for all documents when query is nil" do
      unique = System.unique_integer([:positive])
      # Use a nested path — list_document_sources(nil) returns folder prefixes, not leaf files.
      source = "nil_query_doc_#{unique}/file.md"
      {:ok, _} = Document.create(%{source: source, content: "hello"})

      results = Ingestion.list_document_sources(nil)
      labels = Enum.map(results, & &1.label)
      assert Enum.any?(labels, &String.contains?(&1, "nil_query_doc_#{unique}"))
    end

    test "returns sources for all documents when query is empty string" do
      unique = System.unique_integer([:positive])
      # Use a nested path — list_document_sources("") returns folder prefixes, not leaf files.
      source = "empty_query_doc_#{unique}/file.md"
      {:ok, _} = Document.create(%{source: source, content: "hello"})

      results = Ingestion.list_document_sources("")
      labels = Enum.map(results, & &1.label)
      assert Enum.any?(labels, &String.contains?(&1, "empty_query_doc_#{unique}"))
    end
  end

  test "request_watch skips an empty-source folder without inserting a blank document" do
    assert %{updated: 0, skipped: 1} = Ingestion.request_watch([%{source: nil, kind: :folder}])
    refute Document.get_by_source("")
  end

  test "list_documents_under_folder/2 handles nil volume and folder paths" do
    {:ok, child} = Document.create(%{source: "./child.md", content: "child"})
    {:ok, _other} = Document.create(%{source: "other.md", content: "other"})

    assert Ingestion.list_documents_under_folder(nil, nil) == [child]
  end

  describe "provider delta edge cases" do
    test "ignores non-map signals without enqueuing jobs" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{jobs: [], removed: 0}} =
                 Ingestion.process_data_source_changes(%{
                   provider: "google_drive",
                   config_id: 42,
                   signals: [nil, "not-a-signal"]
                 })
      end)
    end

    test "ignores removed records without an id" do
      record = %Record{id: nil, kind: :file, name: "missing-id"}

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{jobs: [], removed: 0}} =
                 Ingestion.process_data_source_changes(%{
                   provider: "google_drive",
                   config_id: 42,
                   signals: [%{record: record, removed: true}]
                 })
      end)
    end

    test "keeps an unwatched matching document when metadata is nil" do
      source = "data_source/google_drive/42/nil-metadata"
      {:ok, doc} = Document.create(%{source: source, content: "keep", metadata: nil})

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{jobs: [], removed: 0}} =
                 Ingestion.process_data_source_changes(%{
                   provider: "google_drive",
                   config_id: 42,
                   signals: [%{provider_record_id: "nil-metadata", removed: true}]
                 })
      end)

      assert Document.get(doc.id)
    end

    test "keeps an unwatched document with empty provider parent ids" do
      source = "data_source/google_drive/42/empty-parents"

      {:ok, doc} =
        Document.create(%{
          source: source,
          content: "keep",
          metadata: %{"provider_parent_ids" => [nil, ""]}
        })

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{jobs: [], removed: 0}} =
                 Ingestion.process_data_source_changes(%{
                   provider: "google_drive",
                   config_id: 42,
                   signals: [%{provider_record_id: "empty-parents", removed: true}]
                 })
      end)

      assert Document.get(doc.id)
    end

    test "enqueues watched records for unknown binary change types" do
      source = "data_source/google_drive/42/unknown-change"
      {:ok, _doc} = Document.create(%{source: source, content: "old", watch_status: "watched"})

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %{jobs: [job], removed: 0}} =
                 Ingestion.process_data_source_changes(%{
                   provider: "google_drive",
                   config_id: 42,
                   signals: [
                     %{
                       provider_record_id: "unknown-change",
                       change_type: "unknown_change",
                       record: %{id: "unknown-change", name: "Changed.md"}
                     }
                   ]
                 })

        persisted_job = Repo.get!(IngestJob, job.id)
        assert persisted_job.mode == "async"
        assert persisted_job.source_record["id"] == "unknown-change"
        assert persisted_job.source_record["kind"] == "file"

        assert persisted_job.source_record["attributes"] == %{
                 "provider" => "google_drive",
                 "config_id" => "42",
                 "provider_record_id" => "unknown-change"
               }

        refute Map.has_key?(persisted_job.source_record, "lifecycle_state")
      end)
    end
  end
end
