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

  test "empty attachments invoke the consumer without source access" do
    assert :sent = DeliveryFiles.with_prepared([], %{}, fn [] -> :sent end)
  end

  property "raw and declared base64 normalization preserve every byte and attachment order" do
    check all(bytes <- binary(max_length: 2_048)) do
      records = [file(bytes), file(Base.encode64(bytes), %{"encoding" => "base64"})]

      assert [raw, decoded] = DeliveryFiles.with_prepared(records, %{}, & &1)
      assert raw == decoded
      assert raw.content == bytes
      assert raw.size == byte_size(bytes)
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

    assert [prepared] = DeliveryFiles.with_prepared([record], %{}, & &1)

    assert prepared == %{
             content: bytes,
             name: "résumé.pdf",
             mime_type: "application/pdf",
             size: 5
           }
  end

  test "missing display metadata receives safe defaults without guessing an encoding" do
    record = %{file("aGVsbG8=") | name: nil, mime_type: nil}

    assert [%{content: "aGVsbG8=", name: "attachment", mime_type: "application/octet-stream"}] =
             DeliveryFiles.with_prepared([record], %{}, & &1)
  end

  test "invalid collections, Records, content, encoding and header metadata stop before consumption" do
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
               DeliveryFiles.with_prepared(records, %{}, fn _ ->
                 flunk("invalid files consumed")
               end)
    end
  end

  test "a path alone is never read as attachment content" do
    fixture = storage_fixture()
    record = %{fixture.record | materialization_handle: nil, path: fixture.path}

    assert {:error, :attachment_content_unavailable} =
             DeliveryFiles.with_prepared([record], %{}, fn _ -> flunk("path consumed") end)

    assert File.read!(fixture.path) == fixture.bytes
  end

  test "lazy disk files use real Storage authorization and materialize once before the consumer" do
    fixture = storage_fixture()
    expect_storage(fixture.opts)

    assert {:ok, :sent} =
             DeliveryFiles.with_prepared(
               [fixture.record],
               %{
                 actor: fixture.actor,
                 token: "destination-secret",
                 incoming: %{author_id: "fake"}
               },
               fn [prepared] ->
                 assert prepared.content == fixture.bytes
                 assert prepared.name == "report.bin"
                 assert prepared.mime_type == "application/octet-stream"
                 assert prepared.size == byte_size(fixture.bytes)
                 {:ok, :sent}
               end,
               node_router: Zaq.NodeRouterMock
             )

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
               DeliveryFiles.with_prepared(
                 [fixture.record],
                 context,
                 fn _ -> flunk("unauthorized files consumed") end,
                 node_router: Zaq.NodeRouterMock
               )
    end
  end

  test "current source grant revocation denies a previously usable handle" do
    fixture = storage_fixture()
    expect_storage(fixture.opts)

    assert [_] =
             DeliveryFiles.with_prepared([fixture.record], %{actor: fixture.actor}, & &1,
               node_router: Zaq.NodeRouterMock
             )

    assert :ok = Permissions.revoke(fixture.resource, fixture.permission)
    expect_storage(fixture.opts)

    assert {:error, "Attachment preparation failed: :unauthorized"} =
             DeliveryFiles.with_prepared([fixture.record], %{actor: fixture.actor}, & &1,
               node_router: Zaq.NodeRouterMock
             )
  end

  test "removed source files fail without consuming partial prepared files" do
    fixture = storage_fixture()
    File.rm!(fixture.path)
    expect_storage(fixture.opts)

    assert {:error, _} =
             DeliveryFiles.with_prepared(
               [file("first"), fixture.record],
               %{actor: fixture.actor},
               fn _ -> flunk("partial files consumed") end,
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
               DeliveryFiles.with_prepared(
                 [%{file(nil) | materialization_handle: handle}],
                 context,
                 & &1
               )
    end
  end

  test "source failures and malformed source payloads return errors before the consumer" do
    assert {:ok, handle} = DiskDocument.issue("source-file")
    record = %{file(nil) | materialization_handle: handle}

    for response <- [
          {:error, :source_unavailable},
          {:ok, %{content: "%%%", encoding: "base64"}},
          {:ok, %{content: %{unexpected: "map"}}}
        ] do
      expect(Zaq.NodeRouterMock, :dispatch, fn event -> %{event | response: response} end)

      assert {:error, _} =
               DeliveryFiles.with_prepared(
                 [record],
                 %TrustedContext{},
                 fn _ -> flunk("failed source consumed") end,
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

    assert [%{name: "source.pdf", mime_type: "application/pdf", content: ^bytes, size: 3}] =
             DeliveryFiles.with_prepared(
               [record],
               %{actor: %{person_id: 123}, credentials: "destination-secret"},
               & &1,
               node_router: Zaq.NodeRouterMock
             )
  end

  test "only a literal trusted bypass allows a nil actor to materialize a private file" do
    fixture = storage_fixture()

    for bypass <- ["true", true] do
      expect_storage(fixture.opts)

      result =
        DeliveryFiles.with_prepared(
          [fixture.record],
          %{actor: nil, skip_permissions: bypass},
          & &1,
          node_router: Zaq.NodeRouterMock
        )

      if bypass == true do
        assert [%{content: content}] = result
        assert content == fixture.bytes
      else
        assert {:error, "Attachment preparation failed: :unauthorized"} = result
      end
    end
  end

  test "invalid handles fail through the registered materialization boundary" do
    for handle <- ["forged-handle", ""] do
      assert {:error, _} =
               DeliveryFiles.with_prepared(
                 [%{file(nil) | materialization_handle: handle}],
                 %{},
                 fn _ ->
                   flunk("invalid handle consumed")
                 end
               )
    end
  end

  test "consumer errors and exceptions propagate without deleting original files" do
    fixture = storage_fixture()
    expect_storage(fixture.opts)

    assert {:error, :transport_unavailable} =
             DeliveryFiles.with_prepared(
               [fixture.record],
               %{actor: fixture.actor},
               fn [_] -> {:error, :transport_unavailable} end,
               node_router: Zaq.NodeRouterMock
             )

    assert File.read!(fixture.path) == fixture.bytes
    expect_storage(fixture.opts)

    assert_raise RuntimeError, "consumer failed", fn ->
      DeliveryFiles.with_prepared(
        [fixture.record],
        %{actor: fixture.actor},
        fn [_] -> raise "consumer failed" end,
        node_router: Zaq.NodeRouterMock
      )
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
