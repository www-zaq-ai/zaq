defmodule Zaq.Channels.DeliveryFilesTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Accounts.People
  alias Zaq.Channels.DeliveryFiles
  alias Zaq.Channels.Materializers.CommunicationMedia
  alias Zaq.Contracts.Record
  alias Zaq.Events.TrustedContext
  alias Zaq.Permissions
  alias Zaq.Storage
  alias Zaq.Storage.Api, as: StorageApi
  alias Zaq.Storage.Materializers.DiskDocument
  alias Zaq.Storage.StorageEntry

  setup :verify_on_exit!

  defmodule StorageConfig do
    def get(:zaq, Zaq.Storage, _default, opts), do: Keyword.fetch!(opts, :storage_config)
  end

  test "empty attachments return no files without source access" do
    assert {:ok, []} = DeliveryFiles.prepare([], %{})
  end

  property "raw and declared base64 normalization preserve every byte and attachment order" do
    check all(bytes <- binary(max_length: 2_048)) do
      records = [file(bytes), file(Base.encode64(bytes), %{"encoding" => "base64"})]

      assert {:ok, [raw, decoded]} = DeliveryFiles.prepare(records, %{})
      assert raw == decoded
      assert raw.content == bytes
      assert raw.size == byte_size(bytes)
    end
  end

  property "standard base64 with whitespace and optional padding preserves every byte" do
    check all(bytes <- binary(max_length: 2_048)) do
      encoded =
        bytes
        |> Base.encode64(padding: false)
        |> String.graphemes()
        |> Enum.chunk_every(7)
        |> Enum.map_join("\r\n", &Enum.join/1)

      record = file(" \t" <> encoded <> "\n", %{"encoding" => "base64"})

      assert {:ok, [prepared]} = DeliveryFiles.prepare([record], %{})
      assert prepared.content == bytes
      assert prepared.size == byte_size(bytes)
    end
  end

  test "malformed and URL-safe base64 retain the attachment error contract" do
    for encoded <- ["%%%", "a", "-_8="] do
      assert {:error, :invalid_attachment_base64} =
               DeliveryFiles.prepare([file(encoded, %{"encoding" => "base64"})], %{})
    end
  end

  test "existing bytes preserve non-UTF8 content and expose only transport fields" do
    bytes = <<0, 255, 254, 128, 10>>

    record = %{
      file(bytes, %{"encoding" => "binary", "token" => "private"})
      | name: "résumé.pdf",
        mime_type: "application/pdf",
        path: "/private/original.pdf",
        url: "https://private.example/file",
        raw: %{credentials: "private"},
        size: 999,
        materialization_handle: "unused"
    }

    assert {:ok, [prepared]} = DeliveryFiles.prepare([record], %{})

    assert prepared == %{
             content: bytes,
             name: "résumé.pdf",
             mime_type: "application/pdf",
             size: 5
           }
  end

  test "missing display metadata receives safe defaults without guessing an encoding" do
    record = %{file("aGVsbG8=") | name: nil, mime_type: nil}

    assert {:ok,
            [%{content: "aGVsbG8=", name: "attachment", mime_type: "application/octet-stream"}]} =
             DeliveryFiles.prepare([record], %{})
  end

  test "invalid collections, Records, content, encoding and header metadata return preparation errors" do
    invalid = [
      nil,
      %{},
      [%{id: "not-a-record", kind: :file, content: "bytes"}],
      [%{file("bytes") | kind: :folder}],
      [%{file("bytes") | id: nil}],
      [file([1, 2, 3])],
      [file(%{bytes: "bytes"})],
      [file("%%%", %{"encoding" => "base64"})],
      [file("abc", %{"encoding" => "gzip"})],
      [%{file("bytes") | attributes: []}],
      [%{file("bytes") | name: "bad\r\nBcc: hidden"}],
      [%{file("bytes") | name: "../private.pdf"}],
      [%{file("bytes") | name: "bad\\private.pdf"}],
      [%{file("bytes") | name: <<255>>}],
      [%{file("bytes") | mime_type: "application/pdf\r\nX-Secret: value"}],
      [%{file("bytes") | mime_type: 42}]
    ]

    for records <- invalid do
      assert {:error, _reason} =
               DeliveryFiles.prepare(records, %{})
    end
  end

  test "a path alone is never read as attachment content" do
    fixture = storage_fixture()
    record = %{fixture.record | materialization_handle: nil, path: fixture.path}

    assert {:error, :attachment_content_unavailable} =
             DeliveryFiles.prepare([record], %{})

    assert File.read!(fixture.path) == fixture.bytes
  end

  test "lazy disk files use real Storage authorization and materialize once during preparation" do
    fixture = storage_fixture()
    expect_storage(fixture.opts)

    assert {:ok, [prepared]} =
             DeliveryFiles.prepare(
               [fixture.record],
               %{
                 actor: fixture.actor,
                 token: "destination-secret",
                 incoming: %{author_id: "fake"}
               },
               node_router: Zaq.NodeRouterMock
             )

    assert prepared.content == fixture.bytes
    assert prepared.name == "report.bin"
    assert prepared.mime_type == "application/octet-stream"
    assert prepared.size == byte_size(fixture.bytes)
    assert File.read!(fixture.path) == fixture.bytes
  end

  test "missing, forged and denied identities cannot read a signed disk source" do
    fixture = storage_fixture()

    for context <- [
          %{},
          %{person_id: fixture.actor.person_id},
          %{incoming: %{person: %{id: fixture.actor.person_id}}, credentials: "fake"},
          %{actor: %{person_id: nil}},
          %{actor: %{person_id: person_fixture().id}}
        ] do
      expect_storage(fixture.opts)

      assert {:error, "Attachment preparation failed: :unauthorized"} =
               DeliveryFiles.prepare(
                 [fixture.record],
                 context,
                 node_router: Zaq.NodeRouterMock
               )
    end
  end

  test "current source grant revocation denies a previously usable handle" do
    fixture = storage_fixture()
    expect_storage(fixture.opts)

    assert {:ok, [_]} =
             DeliveryFiles.prepare([fixture.record], %{actor: fixture.actor},
               node_router: Zaq.NodeRouterMock
             )

    assert :ok = Permissions.revoke(fixture.resource, fixture.permission)
    expect_storage(fixture.opts)

    assert {:error, "Attachment preparation failed: :unauthorized"} =
             DeliveryFiles.prepare([fixture.record], %{actor: fixture.actor},
               node_router: Zaq.NodeRouterMock
             )
  end

  test "removed source files fail without returning partial prepared files" do
    fixture = storage_fixture()
    File.rm!(fixture.path)
    expect_storage(fixture.opts)

    assert {:error, _} =
             DeliveryFiles.prepare(
               [file("first"), fixture.record],
               %{actor: fixture.actor},
               node_router: Zaq.NodeRouterMock
             )
  end

  test "communication handles cannot use incoming author or request bypass to forge identity" do
    assert {:ok, handle} =
             CommunicationMedia.issue("mattermost", "source-file", %{
               "source_author_id" => "owner"
             })

    for context <- [
          %{incoming: %{author_id: "owner"}},
          %{actor: %{id: "other"}, request: %{skip_permissions: true, actor: %{id: "owner"}}},
          %{actor: nil, skip_permissions: "true"}
        ] do
      assert {:error, "Attachment preparation failed: :unauthorized_materialization_handle"} =
               DeliveryFiles.prepare(
                 [%{file(nil) | materialization_handle: handle}],
                 context
               )
    end
  end

  test "source failures and malformed source payloads return preparation errors" do
    assert {:ok, handle} = DiskDocument.issue("source-file")
    record = %{file(nil) | materialization_handle: handle}

    for response <- [
          {:error, :source_unavailable},
          {:ok, %{content: "%%%", encoding: "base64"}},
          {:ok, %{content: %{unexpected: "map"}}}
        ] do
      expect(Zaq.NodeRouterMock, :dispatch, fn event -> %{event | response: response} end)

      assert {:error, _} =
               DeliveryFiles.prepare(
                 [record],
                 %TrustedContext{},
                 node_router: Zaq.NodeRouterMock
               )
    end
  end

  test "materialized representation metadata takes precedence over original source metadata" do
    assert {:ok, handle} = DiskDocument.issue("source-file")

    record = %{
      file(nil)
      | name: "source.doc",
        mime_type: "application/msword",
        materialization_handle: handle
    }

    bytes = <<255, 0, 128>>

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.actor == %{person_id: 123}
      refute Keyword.has_key?(event.opts, :credentials)

      %{
        event
        | response:
            {:ok,
             %{
               record: %Record{
                 id: "source-file",
                 kind: :file,
                 name: "source.pdf",
                 mime_type: "application/pdf",
                 content: Base.encode64(bytes),
                 attributes: %{"encoding" => "base64"}
               }
             }}
      }
    end)

    assert {:ok, [%{name: "source.pdf", mime_type: "application/pdf", content: ^bytes, size: 3}]} =
             DeliveryFiles.prepare(
               [record],
               %{actor: %{person_id: 123}, credentials: "destination-secret"},
               node_router: Zaq.NodeRouterMock
             )
  end

  test "only a literal trusted bypass allows a nil actor to materialize a private file" do
    fixture = storage_fixture()

    for bypass <- ["true", true] do
      expect_storage(fixture.opts)

      result =
        DeliveryFiles.prepare(
          [fixture.record],
          %{actor: nil, skip_permissions: bypass},
          node_router: Zaq.NodeRouterMock
        )

      if bypass == true do
        assert {:ok, [%{content: content}]} = result
        assert content == fixture.bytes
      else
        assert {:error, "Attachment preparation failed: :unauthorized"} = result
      end
    end
  end

  test "invalid handles fail through the registered materialization boundary" do
    for handle <- ["forged-handle", ""] do
      assert {:error, _} =
               DeliveryFiles.prepare(
                 [%{file(nil) | materialization_handle: handle}],
                 %{}
               )
    end
  end

  test "consumer errors and exceptions propagate without deleting original files" do
    fixture = storage_fixture()
    expect_storage(fixture.opts)

    result =
      with {:ok, [_]} <-
             DeliveryFiles.prepare([fixture.record], %{actor: fixture.actor},
               node_router: Zaq.NodeRouterMock
             ) do
        {:error, :transport_unavailable}
      end

    assert {:error, :transport_unavailable} = result
    assert File.read!(fixture.path) == fixture.bytes
    expect_storage(fixture.opts)

    assert_raise RuntimeError, "consumer failed", fn ->
      with {:ok, [_]} <-
             DeliveryFiles.prepare([fixture.record], %{actor: fixture.actor},
               node_router: Zaq.NodeRouterMock
             ) do
        raise "consumer failed"
      end
    end

    assert File.read!(fixture.path) == fixture.bytes
  end

  defp file(content, attributes \\ %{}) do
    %Record{
      id: "explicit-file",
      kind: :file,
      name: "report.bin",
      mime_type: "application/octet-stream",
      content: content,
      attributes: attributes
    }
  end

  defp storage_fixture do
    root = Path.join(System.tmp_dir!(), "delivery_files_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    path = Path.join(root, "report.bin")
    bytes = <<0, 255, 254, 128, 10>>
    File.write!(path, bytes)
    on_exit(fn -> File.rm_rf!(root) end)

    opts = [config: StorageConfig, storage_config: [base_path: root, volumes: %{"files" => root}]]
    assert {:ok, entry} = Storage.file_info("files", "report.bin", opts)
    resource = %StorageEntry{id: entry.id}
    actor = %{person_id: person_fixture().id}
    assert {:ok, permission} = Permissions.grant(resource, %{person_id: actor.person_id})
    assert {:ok, handle} = DiskDocument.issue(entry.id)

    %{
      path: path,
      bytes: bytes,
      actor: actor,
      resource: resource,
      permission: permission,
      opts: opts,
      record: %{file(nil) | materialization_handle: handle}
    }
  end

  defp expect_storage(opts) do
    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.next_hop.destination == :storage
      assert event.opts[:action] == :materialize_document
      refute Map.has_key?(event.request, :credentials)
      refute Keyword.has_key?(event.opts, :token)
      event = %{event | opts: Keyword.merge(event.opts, opts)}
      StorageApi.handle_event(event, :materialize_document, nil)
    end)
  end

  defp person_fixture do
    unique = System.unique_integer([:positive])
    {:ok, person} = People.create_person(%{full_name: "Delivery Person #{unique}"})
    person
  end
end
