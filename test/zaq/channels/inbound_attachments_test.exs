defmodule Zaq.Channels.InboundAttachmentsTest do
  # The provider fetch and the volume write are both stubbed at the router, so these assert
  # what this module asks for and where it decides to put the file — never the far ends.
  use Zaq.DataCase, async: false

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.InboundAttachments
  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.Ingestion.FileExplorer.Entry

  defmodule StubRouter do
    @moduledoc false

    def dispatch(%Event{} = event) do
      action = event.opts[:action]
      send(self(), {:dispatch, event.next_hop.destination, action, event.request})
      %{event | response: Process.get({:stub, action}, {:error, :no_stub})}
    end
  end

  defp stub(action, response), do: Process.put({:stub, action}, response)

  defp materializing_event do
    Event.new(%{file_ref: "telegram://file/abc", provider: "telegram"}, :channels,
      opts: [action: :materialize_inbound_attachment]
    )
  end

  defp record(attrs \\ %{}) do
    struct!(
      %Record{
        id: "telegram://file/abc",
        kind: :file,
        content: nil,
        name: "photo.jpg",
        mime_type: "image/jpeg",
        materializing_event: materializing_event()
      },
      attrs
    )
  end

  defp stored_entry do
    %Entry{
      id: "42",
      name: "photo.jpg",
      type: :file,
      size: 2,
      volume: "alpha",
      relative_path: "attachments/person-7/photo.jpg",
      source: "alpha/attachments/person-7/photo.jpg"
    }
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        record: record(),
        provider: "telegram",
        person_id: 7,
        person_name: "Jad Tarabay",
        node_router: StubRouter
      },
      overrides
    )
  end

  setup do
    stub(
      :materialize_inbound_attachment,
      {:ok,
       %{
         record: %Record{
           id: "x",
           kind: :file,
           content: "aGk=",
           attributes: %{"encoding" => "base64"}
         }
       }}
    )

    stub(:list_volumes, {:ok, %{"zeta" => "/vol/zeta", "alpha" => "/vol/alpha"}})
    stub(:persist_record, {:ok, %{status: "created", entry: stored_entry()}})
    :ok
  end

  describe "persist/1" do
    test "materializes through the record's own event and returns the stored record" do
      assert {:ok, %{record: %Record{id: "42", kind: :file}}} =
               InboundAttachments.persist(request())

      assert_received {:dispatch, :channels, :materialize_inbound_attachment,
                       %{file_ref: "telegram://file/abc"}}
    end

    test "the returned record is unmaterialized again, now backed by ingestion" do
      {:ok, %{record: stored}} = InboundAttachments.persist(request())

      assert stored.content == nil
      assert %Event{} = stored.materializing_event
      assert stored.materializing_event.opts[:action] == :materialize_record
    end

    test "asks ingestion to write under the resolved person, then the channel" do
      InboundAttachments.persist(request())

      assert_received {:dispatch, :ingestion, :persist_record, params}

      assert params["name"] == "photo.jpg"
      assert params["path"] == "alpha/attachments/jad-tarabay-7/telegram"
      assert params["content"] == "aGk="
      assert params["encoding"] == "base64"
    end

    test "the same person on two channels lands in two folders under one owner" do
      InboundAttachments.persist(request())
      assert_received {:dispatch, :ingestion, :persist_record, %{"path" => telegram_path}}

      InboundAttachments.persist(request(%{provider: "discord"}))
      assert_received {:dispatch, :ingestion, :persist_record, %{"path" => discord_path}}

      assert telegram_path == "alpha/attachments/jad-tarabay-7/telegram"
      assert discord_path == "alpha/attachments/jad-tarabay-7/discord"
    end

    test "falls back to a named channel segment when the provider is missing" do
      InboundAttachments.persist(request(%{provider: nil}))

      assert_received {:dispatch, :ingestion, :persist_record, %{"path" => path}}
      assert path == "alpha/attachments/jad-tarabay-7/unknown"
    end

    test "picks the alphabetically first volume when no channel names one" do
      InboundAttachments.persist(request())

      assert_received {:dispatch, :ingestion, :persist_record, %{"path" => path}}
      assert String.starts_with?(path, "alpha/")
    end

    test "prefers the volume configured on the channel" do
      {:ok, _config} =
        ChannelConfig.upsert_by_provider("telegram", %{
          name: "tg",
          provider: "telegram",
          kind: "retrieval",
          url: "https://api.telegram.org",
          token: "t",
          settings: %{"attachments" => %{"volume" => "media"}}
        })

      InboundAttachments.persist(request())

      assert_received {:dispatch, :ingestion, :persist_record, %{"path" => path}}
      assert String.starts_with?(path, "media/")
    end

    test "falls back to the person id when the name has no usable characters" do
      for name <- [nil, "", "   ", "***", "日本語"] do
        InboundAttachments.persist(request(%{person_name: name}))

        assert_received {:dispatch, :ingestion, :persist_record, %{"path" => path}}
        assert path == "alpha/attachments/person-7/telegram", "failed for #{inspect(name)}"
      end
    end

    test "a name cannot break out of its folder or introduce separators" do
      for name <- ["../../etc", "a/b/c", "Jad\\Tarabay", "..", "with spaces & symbols!"] do
        InboundAttachments.persist(request(%{person_name: name}))

        assert_received {:dispatch, :ingestion, :persist_record, %{"path" => path}}
        [_volume, "attachments", owner, _channel] = Path.split(path)

        refute owner =~ ~r{[/\\]}
        refute owner == ".."
        assert owner =~ ~r/^[a-z0-9-]+$/
      end
    end

    test "accents are folded rather than dropped into an unusable name" do
      InboundAttachments.persist(request(%{person_name: "Jaïd Tàrabay"}))

      assert_received {:dispatch, :ingestion, :persist_record, %{"path" => path}}
      assert path == "alpha/attachments/jaid-tarabay-7/telegram"
    end

    test "a very long name is truncated so the path stays writable" do
      InboundAttachments.persist(request(%{person_name: String.duplicate("a", 300)}))

      assert_received {:dispatch, :ingestion, :persist_record, %{"path" => path}}
      [_volume, "attachments", owner, _channel] = Path.split(path)
      assert String.length(owner) <= 80
    end

    test "files an unresolved sender under an anonymous owner keyed by author" do
      InboundAttachments.persist(request(%{person_id: nil, author_id: "555"}))

      assert_received {:dispatch, :ingestion, :persist_record, %{"path" => path}}
      assert path == "alpha/attachments/anonymous-555/telegram"
    end

    test "falls back to a bare anonymous owner when there is no author either" do
      InboundAttachments.persist(request(%{person_id: nil, author_id: nil}))

      assert_received {:dispatch, :ingestion, :persist_record, %{"path" => path}}
      assert path == "alpha/attachments/anonymous/telegram"
    end

    test "derives a file name from the record id when the media had no filename" do
      InboundAttachments.persist(request(%{record: record(%{name: nil})}))

      assert_received {:dispatch, :ingestion, :persist_record, %{"name" => "abc"}}
    end

    test "keeps a nested name from escaping its directory" do
      InboundAttachments.persist(request(%{record: record(%{name: "../../etc/passwd"})}))

      assert_received {:dispatch, :ingestion, :persist_record, %{"name" => name}}
      refute name =~ "/"
      assert name == "passwd"
    end

    test "skips the fetch when the record already carries its content" do
      InboundAttachments.persist(request(%{record: record(%{content: "YWxyZWFkeQ=="})}))

      refute_received {:dispatch, :channels, :materialize_inbound_attachment, _}
      assert_received {:dispatch, :ingestion, :persist_record, %{"content" => "YWxyZWFkeQ=="}}
    end

    test "returns the provider's error without attempting a write" do
      stub(:materialize_inbound_attachment, {:error, :file_gone})

      assert {:error, :file_gone} = InboundAttachments.persist(request())
      refute_received {:dispatch, :ingestion, :persist_record, _}
    end

    test "returns the volume write error" do
      stub(:persist_record, {:error, :volume_required})

      assert {:error, :volume_required} = InboundAttachments.persist(request())
    end

    test "refuses a record that has no way to be materialized" do
      assert {:error, :not_materializable} =
               InboundAttachments.persist(request(%{record: record(%{materializing_event: nil})}))
    end

    test "errors when no volume is mounted" do
      stub(:list_volumes, {:ok, %{}})

      assert {:error, :no_volume_configured} = InboundAttachments.persist(request())
      refute_received {:dispatch, :ingestion, :persist_record, _}
    end

    test "rejects a request with no record" do
      assert {:error, :record_required} = InboundAttachments.persist(%{provider: "telegram"})
    end

    test "surfaces an unexpected materialize response rather than guessing" do
      stub(:materialize_inbound_attachment, {:ok, :surprise})

      assert {:error, {:unexpected_materialize_response, {:ok, :surprise}}} =
               InboundAttachments.persist(request())
    end
  end
end
