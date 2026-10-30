defmodule Zaq.Channels.JidoChatDeliveryTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Jido.Chat.Mattermost.Adapter
  alias Zaq.Accounts.{People, PeopleAuth, PeoplePermissions, PersonLoginChallenge}
  alias Zaq.Channels.Api
  alias Zaq.Channels.{EmailBridge, JidoChatBridge}
  alias Zaq.Channels.Materializers.CommunicationMedia
  alias Zaq.Contracts.Record
  alias Zaq.Engine.{ChannelConfig, Events, PeopleAuthGateway}
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Engine.Notifications.NotificationLog
  alias Zaq.Event
  alias Zaq.Events.TrustedContext
  alias Zaq.TestSupport.OpenAIStub

  defmodule FileTransport do
    def upload_file(channel, file, opts) do
      send(self(), {:file_upload, channel, file, opts})

      case URI.parse(opts[:url]).path do
        "/upload_failed" ->
          {:error, :upload_failed}

        "/size_rejected" ->
          {:error, {413, %{"message" => "private-provider-detail"}}}

        "/upload_timeout" ->
          {:error, :timeout}

        path when path in ["/notice_failed", "/notice_raised", "/notice_exit"] ->
          {:error, :upload_failed}

        _ ->
          {:ok, %{"file_infos" => [%{"id" => "upload-id", "name" => file.filename}]}}
      end
    end

    def send_message(channel, text, opts) do
      send(self(), {:file_post, channel, text, opts})

      case URI.parse(opts[:url]).path do
        "/post_failed" -> {:error, {500, %{"message" => "private-provider-detail"}}}
        "/post_timeout" -> {:error, %Req.TransportError{reason: :timeout}}
        "/missing_post_id" -> {:ok, %{"channel_id" => channel}}
        _ -> {:ok, %{"id" => "final-post-id", "channel_id" => channel}}
      end
    end
  end

  defmodule FailingEditAdapter do
    defdelegate send_file(channel, file, opts), to: Adapter

    def edit_message(channel, message_id, text, opts) do
      send(self(), {:file_status, channel, message_id, text, opts})

      case URI.parse(opts[:url]).path do
        "/notice_raised" -> raise "status failed"
        "/notice_exit" -> exit(:status_failed)
      end
    end
  end

  defmodule FileReplyWorker do
    use Oban.Worker, queue: :default
    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  defmodule ExitingReplyWorker do
    def new(_args), do: exit(:callback_failed)
  end

  setup do
    Code.ensure_loaded!(Adapter)
    previous = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      email: %{bridge: EmailBridge},
      mattermost: %{bridge: JidoChatBridge, adapter: Adapter}
    })

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
    {:ok, registry: previous}
  end

  for provider <- ["mattermost", :mattermost], thread_id <- [nil, "root-post"] do
    @provider provider
    @thread_id thread_id
    test "real Thread creates #{inspect(provider)} notification with root #{inspect(thread_id)}" do
      connection = http_server()

      outgoing = %Outgoing{
        provider: @provider,
        channel_id: "private-room",
        thread_id: @thread_id,
        body: "Synthetic private code 1234-5678",
        metadata: %{"subject" => "Sign-in"}
      }

      assert {:ok, %{confirmation: :confirmed, action: :created, message_id: "sent-post"}} =
               JidoChatBridge.send_reply(outgoing, connection)

      assert_received {:openai_request, "POST", "/api/v4/posts", "", body}
      expected = %{"channel_id" => "private-room", "message" => outgoing.body}
      expected = if @thread_id, do: Map.put(expected, "root_id", @thread_id), else: expected
      assert Jason.decode!(body) == expected
    end
  end

  test "ordinary string-provider status edit uses the real adapter edit payload" do
    connection = http_server()

    outgoing = %Outgoing{
      provider: "mattermost",
      channel_id: "private-room",
      body: "Updated answer",
      metadata: %{message_id: "status-post"}
    }

    assert {:ok, %{confirmation: :confirmed, action: :updated, message_id: "status-post"}} =
             JidoChatBridge.send_reply(outgoing, connection)

    assert_received {:openai_request, "PUT", "/api/v4/posts/status-post", "", body}
    assert Jason.decode!(body) == %{"id" => "status-post", "message" => "Updated answer"}
    refute_received {:openai_request, "POST", _, _, _}
  end

  test "files use exact bytes, filename, MIME, caption and thread then return the final post ID" do
    bytes = <<255, 0, 128, 10>>
    outgoing = file_outgoing(bytes)

    assert {:ok, %{confirmation: :confirmed, action: :created, message_id: "final-post-id"}} =
             JidoChatBridge.send_reply(outgoing, file_connection())

    assert_received {:file_upload, "private-room", upload, upload_opts}
    assert upload == %{body: bytes, filename: "résumé.pdf", content_type: "application/pdf"}
    assert upload_opts[:thread_id] == "root-post"
    assert_received {:file_post, "private-room", "File caption", post_opts}
    assert post_opts[:thread_id] == "root-post"
    assert post_opts[:file_ids] == ["upload-id"]
    refute_received {:file_upload, _, _, _}
    refute_received {:file_post, _, _, _}
  end

  test "confirmed files reuse incoming media descriptors for history on create and edit" do
    {child, endpoint} =
      OpenAIStub.server(
        fn conn, body ->
          case conn.request_path do
            "/api/v4/files" ->
              {201,
               %{
                 "file_infos" => [
                   %{
                     "id" => "channel-file",
                     "name" => "image.png",
                     "mime_type" => "image/png",
                     "size" => 2
                   }
                 ]
               }}

            _ ->
              {200,
               Map.merge(Jason.decode!(body), %{
                 "id" => "delivered-post",
                 "user_id" => "bot-author"
               })}
          end
        end,
        self()
      )

    start_supervised!(child)
    connection = %{url: String.trim_trailing(endpoint, "/v1"), token: "synthetic-token"}

    for metadata <- [%{}, %{message_id: "delivered-post"}] do
      outgoing = %{
        file_outgoing()
        | metadata: metadata,
          routing_context: %{channel_config_id: 10}
      }

      assert {:ok, %{attachments: [descriptor]}} = JidoChatBridge.send_reply(outgoing, connection)
      assert descriptor["id"] == "channel-file"
      assert descriptor["mime_type"] == "image/png"
      source = descriptor["attributes"]["materialization_source"]["locator"]
      assert source["reference"] == "channel-file"
      assert source["source_author_id"] == "bot-author"
      assert source["source_message_id"] == "delivered-post"
      assert source["channel_config_id"] == "10"
      refute Map.has_key?(descriptor, "content")
      refute Map.has_key?(descriptor, "materialization_handle")

      assert {:ok, hydrated} =
               CommunicationMedia.hydrate(
                 %{
                   descriptor: descriptor,
                   transcript_id: Ecto.UUID.generate(),
                   message_id: Ecto.UUID.generate()
                 },
                 %{actor: %{person: %{id: 9}}}
               )

      assert hydrated.id == "channel-file"
      assert is_binary(hydrated.materialization_handle)
      assert hydrated.content == nil
    end
  end

  test "final attachments update the streamed answer instead of creating a duplicate post" do
    {child, endpoint} =
      OpenAIStub.server(
        fn conn, body ->
          case {conn.method, conn.request_path} do
            {"POST", "/api/v4/files"} ->
              {201, %{"file_infos" => [%{"id" => "uploaded-file"}]}}

            {"POST", "/api/v4/posts"} ->
              payload = Jason.decode!(body)
              id = if payload["file_ids"], do: "duplicate-post", else: "streamed-post"
              {201, Map.put(payload, "id", id)}

            {"PUT", "/api/v4/posts/streamed-post/patch"} ->
              {200, Map.put(Jason.decode!(body), "id", "streamed-post")}
          end
        end,
        self()
      )

    start_supervised!(child)
    connection = %{url: String.trim_trailing(endpoint, "/v1"), token: "synthetic-token"}
    outgoing = file_outgoing()

    assert {:ok, %{message_id: "streamed-post"}} =
             JidoChatBridge.upsert_message(
               %{provider: "mattermost", provider_atom: :mattermost},
               %{
                 channel_id: outgoing.channel_id,
                 thread_id: outgoing.thread_id,
                 body: outgoing.body
               },
               connection
             )

    assert_received {:openai_request, "POST", "/api/v4/posts", "", streamed_body}
    assert Jason.decode!(streamed_body)["message"] == outgoing.body

    assert {:ok, receipt} =
             JidoChatBridge.send_reply(
               %{
                 outgoing
                 | metadata: %{
                     "message_id" => "streamed-post",
                     "on_reply" => %{"module" => Atom.to_string(FileReplyWorker), "args" => %{}}
                   }
               },
               connection
             )

    assert_received {:openai_request, "POST", "/api/v4/files", "", _upload}
    refute_received {:openai_request, "POST", "/api/v4/posts", "", _duplicate}
    assert_received {:openai_request, "PUT", "/api/v4/posts/streamed-post/patch", "", final_body}
    assert Jason.decode!(final_body)["message"] == outgoing.body
    assert Jason.decode!(final_body)["file_ids"] == ["uploaded-file"]
    assert receipt.message_id == "streamed-post"
    assert receipt.confirmation == :confirmed

    assert [%{args: %{"post_id" => "streamed-post"}}] =
             Oban.Testing.all_enqueued(repo: Repo, worker: FileReplyWorker)
  end

  test "recording failure never resends files and a repeated caller submission remains another send" do
    {child, endpoint} =
      OpenAIStub.server(
        fn conn, _body ->
          case conn.request_path do
            "/api/v4/files" -> {201, %{"file_infos" => [%{"id" => "uploaded-file"}]}}
            "/api/v4/posts" -> {201, %{"id" => "accepted-post", "channel_id" => "private-room"}}
          end
        end,
        self()
      )

    start_supervised!(child)

    assert {:ok, config} =
             ChannelConfig.upsert_by_provider("mattermost", %{
               name: "File confirmation lifecycle",
               kind: "retrieval",
               enabled: true,
               url: String.trim_trailing(endpoint, "/v1"),
               token: "synthetic-token"
             })

    outgoing = %{
      file_outgoing()
      | routing_context: %{channel_config_id: config.id},
        metadata: %{assistant_message_id: "persisted-answer"}
    }

    event =
      Event.new(outgoing, :channels,
        opts: [action: :deliver_outgoing, delivery_node_router: Zaq.NodeRouterMock]
      )

    expect(Zaq.NodeRouterMock, :dispatch, 2, fn confirmation ->
      send(self(), {:file_confirmation, confirmation})
      %{confirmation | response: {:error, :engine_unavailable}}
    end)

    for _submission <- 1..2 do
      assert {:ok,
              %{
                confirmation: :confirmed,
                message_id: "accepted-post",
                confirmation_recording: :unavailable
              }} =
               Api.handle_event(event, :deliver_outgoing, nil).response

      assert_received {:openai_request, "POST", "/api/v4/files", "", _upload}
      assert_received {:openai_request, "POST", "/api/v4/posts", "", post}
      assert Jason.decode!(post)["file_ids"] == ["uploaded-file"]
      assert_received {:file_confirmation, confirmation}
      assert confirmation.opts[:action] == :record_delivery_confirmation
      [original_attachment] = outgoing.attachments
      assert confirmation.request.outgoing.attachments == [%{original_attachment | content: nil}]
      assert confirmation.request.outgoing.metadata == %{assistant_message_id: "persisted-answer"}
      assert confirmation.request.receipt.message_id == "accepted-post"
      refute_received {:openai_request, _, _, _, _}
    end

    verify!(Zaq.NodeRouterMock)
  end

  test "files update the existing post without duplicating the answer or appending success text" do
    outgoing = %{file_outgoing() | metadata: %{message_id: "status-id", format: :markdown}}

    assert {:ok, %{action: :updated, message_id: "status-id"}} =
             JidoChatBridge.send_reply(outgoing, file_connection())

    assert_received {:file_upload, _, _, _}
    assert_received {:file_status, _, "status-id", "File caption", [file_ids: ["upload-id"]]}
    refute_received {:file_upload, _, _, _}
    refute_received {:file_post, _, _, _}
    refute_received {:file_status, _, _, _, _}
  end

  test "real adapter collection rejection is reported without sending a subset" do
    outgoing = file_outgoing()

    outgoing = %{
      outgoing
      | attachments: outgoing.attachments ++ outgoing.attachments,
        metadata: %{message_id: "status-id"}
    }

    assert {:error, :multiple_attachments_unsupported} =
             JidoChatBridge.send_reply(outgoing, file_connection())

    assert_received {:file_status, _, "status-id", status, _}

    assert status ==
             "File caption\n\nFile delivery failed: Sending multiple attachments together is not supported."

    refute_received {:file_upload, _, _, _}
    refute_received {:file_post, _, _, _}
  end

  test "provider rejection preserves the answer and HTTP status without exposing response details" do
    outgoing = %{file_outgoing() | metadata: %{message_id: "status-id"}}

    assert {:error, {413, _}} =
             JidoChatBridge.send_reply(outgoing, file_connection("size_rejected"))

    assert_received {:file_upload, _, _, _}
    assert_received {:file_status, _, _, status, _}
    assert status == "File caption\n\nFile delivery failed: The provider returned HTTP 413."
    refute status =~ "private-provider-detail"
    refute_received {:file_post, _, _, _}
    refute_received {:file_upload, _, _, _}
  end

  test "upload and attachment update failures retain errors and report only generic safe status" do
    for failure <- ["upload_failed", "post_failed"] do
      outgoing = %{file_outgoing() | metadata: %{message_id: "status-id"}}
      assert {:error, _} = JidoChatBridge.send_reply(outgoing, file_connection(failure))
      assert_received {:file_upload, _, _, _}
      if failure == "post_failed", do: assert_received({:file_edit, _, "status-id", _, _})
      assert_received {:file_status, _, _, status, _}
      assert String.starts_with?(status, "File caption\n\nFile delivery failed: ")
      refute status =~ "private-provider-detail"
      refute_received {:file_upload, _, _, _}
      refute_received {:file_post, _, _, _}
      refute_received {:file_edit, _, _, _, _}
    end
  end

  test "ambiguous upload or attachment update timeouts report uncertainty and never send again" do
    for failure <- ["upload_timeout", "post_timeout"] do
      outgoing = %{file_outgoing() | metadata: %{message_id: "status-id"}}
      assert {:error, _} = JidoChatBridge.send_reply(outgoing, file_connection(failure))
      assert_received {:file_upload, _, _, _}
      if failure == "post_timeout", do: assert_received({:file_edit, _, "status-id", _, _})
      assert_received {:file_status, _, _, status, _}

      assert status ==
               "File caption\n\nFile delivery could not be confirmed: Check the conversation before sending again."

      refute_received {:file_upload, _, _, _}
      refute_received {:file_post, _, _, _}
      refute_received {:file_edit, _, _, _, _}
    end
  end

  test "file delivery preserves Jido's generated post ID when the provider ID is absent" do
    outgoing = %{
      file_outgoing()
      | metadata: %{
          "on_reply" => %{"module" => Atom.to_string(FileReplyWorker), "args" => %{}}
        }
    }

    assert {:ok, %{confirmation: :confirmed, action: :created, message_id: message_id}} =
             JidoChatBridge.send_reply(outgoing, file_connection("missing_post_id"))

    assert is_binary(message_id) and byte_size(message_id) > 0
    refute message_id in ["status-id", "upload-id"]

    assert [%{args: %{"post_id" => ^message_id}}] =
             Oban.Testing.all_enqueued(repo: Repo, worker: FileReplyWorker)

    assert_received {:file_upload, _, _, _}
    assert_received {:file_post, _, _, _}
    refute_received {:file_status, _, _, _, _}
    refute_received {:file_upload, _, _, _}
    refute_received {:file_post, _, _, _}
  end

  test "confirmed delivery survives status errors, exceptions and exits with one upload and post" do
    for failure <- ["status_failed", "status_raised", "status_exit"] do
      outgoing = file_outgoing()

      capture_log(fn ->
        assert {:ok, %{confirmation: :confirmed, message_id: "final-post-id"}} =
                 JidoChatBridge.send_reply(outgoing, file_connection(failure))
      end)

      assert_received {:file_upload, _, _, _}
      assert_received {:file_post, _, _, _}
      refute_received {:file_status, _, _, _, _}
      refute_received {:file_upload, _, _, _}
      refute_received {:file_post, _, _, _}
    end
  end

  test "on_reply tracks the final post ID and callback exits cannot repeat the send" do
    for worker <- [FileReplyWorker, ExitingReplyWorker] do
      outgoing = %{
        file_outgoing()
        | metadata: %{"on_reply" => %{"module" => Atom.to_string(worker), "args" => %{}}}
      }

      capture_log(fn ->
        assert {:ok, %{confirmation: :confirmed, message_id: "final-post-id"}} =
                 JidoChatBridge.send_reply(outgoing, file_connection())
      end)

      if worker == FileReplyWorker do
        assert [%{args: %{"post_id" => "final-post-id"}}] =
                 Oban.Testing.all_enqueued(repo: Repo, worker: FileReplyWorker)
      end

      assert_received {:file_upload, _, _, _}
      assert_received {:file_post, _, _, _}
      refute_received {:file_upload, _, _, _}
      refute_received {:file_post, _, _, _}
    end
  end

  test "preparation errors preserve the answer with a notice and unsupported bodies are not sent" do
    assert {:ok, handle} =
             CommunicationMedia.issue("mattermost", "private-file", %{
               "source_author_id" => "owner"
             })

    cases = [
      {%{file_outgoing() | attachments: nil}, :invalid_attachments},
      {%{
         file_outgoing()
         | attachments: [
             %{hd(file_outgoing().attachments) | content: nil, materialization_handle: handle}
           ]
       }, "Attachment preparation failed: :unauthorized_materialization_handle"},
      {%{file_outgoing() | body: 123}, :invalid_postable},
      {%{file_outgoing() | body: %{text: "hidden file", attachments: [%{path: "/private/file"}]}},
       :invalid_postable},
      {%{file_outgoing() | body: 123, attachments: []}, :invalid_postable}
    ]

    for {outgoing, reason} <- cases do
      assert {:error, ^reason} = JidoChatBridge.send_reply(outgoing, file_connection())
      refute_received {:file_upload, _, _, _}

      if is_binary(outgoing.body) do
        assert_received {:file_post, _, text, opts}
        assert text == "File caption\n\nFile delivery failed: The attachment could not be sent."
        assert opts[:file_ids] == nil
      end

      refute_received {:file_post, _, _, _}
    end
  end

  test "failure without a placeholder sends the answer and reason once without attachments or callback" do
    outgoing = %{
      file_outgoing()
      | metadata: %{"on_reply" => %{"module" => Atom.to_string(FileReplyWorker), "args" => %{}}}
    }

    assert {:error, :upload_failed} =
             JidoChatBridge.send_reply(outgoing, file_connection("upload_failed"))

    assert_received {:file_upload, _, _, _}
    assert_received {:file_post, "private-room", text, opts}
    assert text == "File caption\n\nFile delivery failed: The attachment could not be sent."
    assert opts[:thread_id] == "root-post"
    assert opts[:file_ids] == nil
    assert Oban.Testing.all_enqueued(repo: Repo, worker: FileReplyWorker) == []
    refute_received {:file_upload, _, _, _}
    refute_received {:file_post, _, _, _}
    refute_received {:file_status, _, _, _, _}
  end

  test "pipeline attachment mistakes reach delivery without losing the answer" do
    incoming = %Zaq.Engine.Messages.Incoming{
      content: "Send the file",
      provider: :mattermost,
      channel_id: "private-room"
    }

    connection = file_connection()

    for attachments <- [nil, [%{id: "not-a-record"}]] do
      outgoing =
        Outgoing.from_pipeline_result(incoming, %{
          answer: "Keep this answer",
          attachments: attachments
        })

      assert {:error, _} = JidoChatBridge.send_reply(outgoing, connection)
      assert_received {:file_post, "private-room", text, opts}
      assert text == "Keep this answer\n\nFile delivery failed: The attachment could not be sent."
      assert opts[:file_ids] == nil
      refute_received {:file_upload, _, _, _}
      refute_received {:file_post, _, _, _}
    end
  end

  test "failure notice errors, exceptions and exits preserve the original failure without retry" do
    registry = Application.fetch_env!(:zaq, :channels)

    for scenario <- ["notice_failed", "notice_raised", "notice_exit"] do
      adapter = if scenario == "notice_failed", do: Adapter, else: FailingEditAdapter
      Application.put_env(:zaq, :channels, put_in(registry, [:mattermost, :adapter], adapter))
      outgoing = %{file_outgoing() | metadata: %{message_id: "status-id"}}

      {original_error, notice} =
        if scenario == "notice_failed" do
          {{400, %{"message" => "private-provider-detail"}}, "The provider returned HTTP 400."}
        else
          {:upload_failed, "The attachment could not be sent."}
        end

      capture_log(fn ->
        assert {:error, ^original_error} =
                 JidoChatBridge.send_reply(outgoing, file_connection(scenario))
      end)

      assert_received {:file_upload, _, _, _}
      assert_received {:file_status, _, "status-id", text, _}
      assert text == "File caption\n\nFile delivery failed: " <> notice
      refute_received {:file_upload, _, _, _}
      refute_received {:file_post, _, _, _}
      refute_received {:file_status, _, _, _, _}
    end
  end

  property "a failure notice preserves the complete answer, including an empty answer" do
    connection = file_connection("upload_failed")

    check all(body <- one_of([constant(""), string(:printable, max_length: 256)])) do
      outgoing = %{file_outgoing() | body: body, metadata: %{message_id: "status-id"}}

      assert {:error, {400, %{"message" => "private-provider-detail"}}} =
               JidoChatBridge.send_reply(outgoing, connection)

      assert_received {:file_upload, _, _, _}
      assert_received {:file_status, _, "status-id", text, _}
      notice = "File delivery failed: The provider returned HTTP 400."
      assert text == if(body == "", do: notice, else: body <> "\n\n" <> notice)
      refute_received {:file_upload, _, _, _}
      refute_received {:file_post, _, _, _}
    end
  end

  defp file_outgoing(content \\ <<255, 0, 128>>) do
    %Outgoing{
      provider: :mattermost,
      channel_id: "private-room",
      thread_id: "root-post",
      body: "File caption",
      attachments: [
        %Record{
          id: "explicit-file",
          kind: :file,
          content: content,
          name: "résumé.pdf",
          mime_type: "application/pdf"
        }
      ]
    }
  end

  defp file_connection(scenario \\ "success") do
    owner = self()

    {child, endpoint} =
      OpenAIStub.server(
        fn conn, body ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer synthetic-token"]
          file_http_response(conn, body, scenario, owner)
        end,
        owner
      )

    start_supervised!(Supervisor.child_spec(child, id: make_ref()))

    %{
      url: String.trim_trailing(endpoint, "/v1") <> "/#{scenario}",
      token: "synthetic-token",
      transport: FileTransport,
      trusted_context: %TrustedContext{}
    }
  end

  defp file_http_response(%{method: "POST"} = conn, body, scenario, owner) do
    assert conn.request_path == "/#{scenario}/api/v4/files"
    assert body =~ "private-room"
    send(owner, {:file_upload, "private-room", %{multipart: body}, []})

    case scenario do
      scenario when scenario in ["upload_failed", "notice_failed"] ->
        {400, %{"message" => "private-provider-detail"}}

      "size_rejected" ->
        {413, %{"message" => "private-provider-detail"}}

      "upload_timeout" ->
        file_http_timeout()

      _ ->
        {201, %{"file_infos" => [%{"id" => "upload-id", "name" => "résumé.pdf"}]}}
    end
  end

  defp file_http_response(%{method: "PUT"} = conn, body, scenario, owner) do
    assert conn.request_path in [
             "/#{scenario}/api/v4/posts/status-id",
             "/#{scenario}/api/v4/posts/status-id/patch"
           ]

    payload = Jason.decode!(body)
    assert payload["id"] == "status-id"
    files = if payload["file_ids"], do: [file_ids: payload["file_ids"]], else: []
    failing_attachment? = files != [] and scenario in ["post_failed", "post_timeout"]
    event = if failing_attachment?, do: :file_edit, else: :file_status
    send(owner, {event, "private-room", payload["id"], payload["message"], files})

    case {scenario, failing_attachment?} do
      {"post_failed", true} -> {500, %{"message" => "private-provider-detail"}}
      {"post_timeout", true} -> file_http_timeout()
      {"notice_failed", _} -> {400, %{"message" => "synthetic edit rejection"}}
      _ -> {200, Map.put(payload, "channel_id", "private-room")}
    end
  end

  defp file_http_timeout do
    # Exercise Req's actual receive timeout without injecting a bridge transport.
    Process.sleep(16_000)
    {200, %{}}
  end

  test "unsupported providers retain the controlled delivery error without interning strings" do
    unknown = "unregistered-provider-#{System.unique_integer([:positive])}"

    for provider <- [unknown, nil, :unsupported] do
      outgoing = %Outgoing{provider: provider, channel_id: "private-room", body: "Harmless"}

      assert {:error, {:unsupported_provider, ^provider}} =
               JidoChatBridge.send_reply(outgoing, %{url: "http://unused.invalid", token: "test"})
    end

    assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(unknown, :utf8) end
  end

  property "registered provider strings and atoms pass the bridge's real Thread constructor", %{
    registry: registry
  } do
    Application.put_env(:zaq, :channels, registry)
    # Read the production registry, rather than maintaining another provider enumeration.
    providers = for {provider, %{adapter: _}} <- registry, do: provider

    check all(provider <- member_of(providers), string? <- boolean()) do
      input = if string?, do: Atom.to_string(provider), else: provider
      assert {:ok, _adapter} = JidoChatBridge.adapter_for(input)
      assert JidoChatBridge.provider_to_atom(input) === provider

      incoming = %Jido.Chat.Incoming{
        external_room_id: "private-room",
        channel_meta: %Jido.Chat.ChannelMeta{adapter_name: input},
        author: %Jido.Chat.Author{is_me: true, user_id: "bot", user_name: "bot"}
      }

      assert :ok =
               JidoChatBridge.handle_from_listener(
                 %{provider: input, url: "http://unused.invalid", token: "test"},
                 incoming,
                 []
               )
    end
  end

  test "listener config string passes the real Thread constructor before ignoring the bot's message" do
    incoming = %Jido.Chat.Incoming{
      external_room_id: "private-room",
      author: %Jido.Chat.Author{is_me: true, user_id: "bot", user_name: "bot"}
    }

    assert :ok =
             JidoChatBridge.handle_from_listener(
               %{provider: "mattermost", url: "http://unused.invalid", token: "test"},
               incoming,
               []
             )
  end

  test "authentication crosses Jido Exec, Engine, Notifications, real Thread and Mattermost HTTP" do
    connection = http_server()
    person = authentication_person(connection)

    log =
      capture_log(fn ->
        event =
          Events.build_and_dispatch_invoke_event(
            %{op: :request_challenge, email: person.email, ip: {127, 0, 3, 41}},
            :people_auth,
            event_opts: [confidential: true]
          )

        assert {:ok, descriptor} = event.response

        assert Enum.sort(Map.keys(descriptor)) == [
                 :challenge_id,
                 :expires_at,
                 :resend_available_at
               ]

        assert {:ok, ^descriptor} = PeopleAuth.challenge_status(descriptor.challenge_id)
        assert_received {:openai_request, "POST", "/api/v4/posts", "", body}
        payload = Jason.decode!(body)
        assert payload["channel_id"] == "private-room"
        refute Map.has_key?(payload, "root_id")
        [_, code] = Regex.run(~r/\*\*([0-9]{4}-[0-9]{4})\*\*/, payload["message"])

        assert payload["message"] ==
                 "Your ZAQ sign-in code is\n\n**#{code}**\n\nDo not share this code.\n\n*Input this code in the current Sign-in page*"

        send(self(), {:delivered_code, code})

        row = Repo.one!(from n in NotificationLog, where: n.recipient_ref_id == ^person.id)
        assert row.status == "sent"
        assert row.payload["body"] == payload["message"]

        assert {:ok, %{token: token}} =
                 PeopleAuthGateway.dispatch(
                   %{op: :verify, challenge_id: descriptor.challenge_id, code: code},
                   []
                 )

        assert {:ok, %{person: authenticated}} =
                 PeopleAuthGateway.dispatch(%{op: :authenticate, token: token}, [])

        assert authenticated.id == person.id
      end)

    assert_received {:delivered_code, code}
    refute log =~ code
    refute log =~ String.replace(code, "-", "")
  end

  test "real HTTP delivery failure invalidates its exact challenge and stores a failed notification" do
    connection = http_server(403)
    person = authentication_person(connection)

    log =
      capture_log(fn ->
        assert {:error, :delivery_failed} =
                 PeopleAuthGateway.request_challenge(person.email, {127, 0, 3, 42})
      end)

    assert_received {:openai_request, "POST", "/api/v4/posts", "", body}
    [code] = Regex.run(~r/[0-9]{4}-[0-9]{4}/, Jason.decode!(body)["message"])
    challenge = Repo.one!(from c in PersonLoginChallenge, where: c.person_id == ^person.id)
    assert challenge.invalidated_at
    assert {:error, :invalid_challenge} = PeopleAuth.challenge_status(challenge.id)
    row = Repo.one!(from n in NotificationLog, where: n.recipient_ref_id == ^person.id)
    assert row.status == "failed"
    refute log =~ code
    refute log =~ String.replace(code, "-", "")
  end

  defp http_server(status \\ 201) do
    {child, endpoint} =
      OpenAIStub.server(
        fn conn, body ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer synthetic-token"]
          payload = Jason.decode!(body)
          {status, Map.merge(payload, %{"id" => "sent-post", "create_at" => 0})}
        end,
        self()
      )

    start_supervised!(child)
    %{url: String.trim_trailing(endpoint, "/v1"), token: "synthetic-token"}
  end

  defp authentication_person(connection) do
    {:ok, config} =
      ChannelConfig.upsert_by_provider("mattermost", %{
        name: "Synthetic delivery",
        kind: "retrieval",
        enabled: true,
        url: connection.url,
        token: connection.token
      })

    {:ok, person} =
      People.create_person(%{full_name: "Delivery", email: "delivery@example.test"})

    {:ok, _} =
      People.add_channel(%{
        person_id: person.id,
        platform: "mattermost",
        channel_config_id: config.id,
        channel_identifier: "private-room",
        weight: 0
      })

    {:ok, _} = PeoplePermissions.grant(:everyone, :access_profile)
    person
  end
end
