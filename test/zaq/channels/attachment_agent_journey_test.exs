defmodule Zaq.Channels.AttachmentAgentJourneyTest do
  use Zaq.DataCase, async: false

  alias Mail.Message, as: MailMessage
  alias Zaq.Accounts.People
  alias Zaq.Agent.{Factory, ServerManager}
  alias Zaq.Agent.Tools.DataSource.AttachDocuments
  alias Zaq.Channels.EmailBridge
  alias Zaq.Channels.EmailBridge.ImapAdapter
  alias Zaq.Contracts.ToolStep
  alias Zaq.Engine.{ChannelConfig, IncomingMessageRouting}
  alias Zaq.Engine.Conversations.Message
  alias Zaq.Permissions
  alias Zaq.Storage
  alias Zaq.Storage.{StorageEntry, VolumeConfig}

  alias Zaq.TestSupport.{
    AttachmentSelectionLLMStub,
    FileDeliverySmtpStub,
    IntegrationAgent,
    MattermostHistoryFixture,
    MultiAgentOpenAIStub,
    OpenAIStub
  }

  @moduletag timeout: 120_000

  setup do
    handler = {__MODULE__, self()}

    :ok =
      :telemetry.attach_many(
        handler,
        [[:zaq, :repo, :query], [:zaq, :node_router, :async, :failed]],
        &__MODULE__.observe_delivery/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  def observe_delivery([:zaq, :repo, :query], _measurements, metadata, owner) do
    if metadata[:source] == "messages" and
         String.starts_with?(metadata.query, ["INSERT", "UPDATE"]) do
      for %{"delivery_confirmation" => %{"channel_config_id" => id}} <-
            metadata[:cast_params] || [] do
        send(owner, {:delivery_writer, id, self()})
      end
    end
  end

  def observe_delivery([:zaq, :node_router, :async, :failed], _measurements, metadata, owner),
    do: send(owner, {:delivery_failed, metadata.trace_id, self()})

  for provider <- [:mattermost, :email], operation <- [:remove, :replace, :repeat, :clear] do
    @provider provider
    @operation operation
    test "#{provider} ingress retrieves real documents and applies #{@operation} before delivery" do
      Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
      owner = self()
      namespace = "attachment-journey-#{Ecto.UUID.generate()}"
      {:ok, person} = People.create_person(%{full_name: namespace})
      {disk, files, root} = documents!(namespace, person)
      destination = destination!(@provider, namespace, owner)

      script =
        [
          get_document(disk, files.a.id),
          &select_documents(&1, "add", [0]),
          get_document(disk, files.b.id),
          &select_documents(&1, "add", [2])
        ] ++ selection_steps(@operation) ++ [{:pause, {:text, final_text(@operation)}}]

      {child, endpoint} =
        AttachmentSelectionLLMStub.server(
          script ++ [{:pause, {:text, "No files selected."}}],
          owner
        )

      start_supervised!(child)

      agent =
        IntegrationAgent.create!(endpoint, namespace, "Select the requested files.", [
          "data_source.get_document",
          "data_source.attach_document"
        ])

      {:ok, agent} = Zaq.Agent.update_agent(agent, %{conversation_enabled: true})

      on_exit(fn -> ServerManager.stop_server(agent) end)
      bind!(destination, person, agent)
      ingress = Task.async(fn -> ingest(destination, "Select A and B, then remove A") end)

      assert_receive {:attachment_model_paused, model}, 15_000
      refute_received {:delivery_upload, _, _}
      refute_received {:delivery_boundary, _, _, _}

      for index <- 0..(length(script) - 1) do
        assert_receive {:attachment_model_request, ^index, request}, 1_000
        assert Enum.any?(request["tools"], &(&1["name"] == "attach_documents"))
        if index > 0, do: assert(MultiAgentOpenAIStub.tool_results(request) != [])
      end

      send(model, :release)
      expected_file = if @operation == :clear, do: nil, else: files.b
      assert_delivery(destination, namespace, expected_file)
      delivered = await_delivery(destination.config.id)
      assert delivered.body == final_text(@operation)

      assert Enum.map(delivered.attachments, & &1.id) ==
               if(expected_file, do: [files.b.id], else: [])

      Task.await(ingress, 10_000)
      await_delivery_writer(destination.config.id)
      refute_receive {:delivery_upload, _, _}
      refute_receive {:delivery_boundary, _, _, _}
      assert File.read!(Path.join(root, "A.txt")) == "A private bytes"
      assert File.read!(Path.join(root, "B.txt")) == "B selected bytes"

      # A second real ingress in the same thread must not inherit the first request's selection.
      followup = Map.put(destination, :message_id, "attachment-followup@example.test")
      next_ingress = Task.async(fn -> ingest(followup, "Thanks, answer without a file") end)
      assert_receive {:attachment_model_paused, next_model}, 15_000
      refute_received {:delivery_upload, _, _}
      send(next_model, :release)
      assert_delivery(followup, namespace, nil)
      assert await_delivery(destination.config.id).attachments == []
      Task.await(next_ingress, 10_000)
      await_delivery_writer(destination.config.id)
      refute_receive {:delivery_upload, _, _}
    end
  end

  for provider <- [:mattermost, :email],
      scenario <- [:failure, :cancel, :steer, :revoke, :privacy] do
    @provider provider
    @scenario scenario
    test "#{provider} attachment journey enforces #{@scenario} at the delivery boundary" do
      Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
      namespace = "attachment-#{@scenario}-#{Ecto.UUID.generate()}"
      {:ok, person} = People.create_person(%{full_name: namespace})
      {disk, files, root} = documents!(namespace, person)
      connections = if @scenario == :revoke, do: 1, else: 2
      destination = destination!(@provider, namespace, self(), connections)

      script =
        [get_document(disk, files.b.id), &select_documents(&1, "add", [0])] ++
          interrupted_steps(@scenario) ++ [{:pause, {:text, "No files selected."}}]

      {child, endpoint} = AttachmentSelectionLLMStub.server(script, self())
      start_supervised!(child)

      agent =
        IntegrationAgent.create!(endpoint, namespace, "Select the requested files.", [
          "data_source.get_document",
          "data_source.attach_document"
        ])

      {:ok, agent} = Zaq.Agent.update_agent(agent, %{conversation_enabled: true})
      on_exit(fn -> ServerManager.stop_server(agent) end)
      bind!(destination, person, agent)
      ingress = Task.async(fn -> ingest(destination, "Retrieve and attach B") end)
      assert_receive {:attachment_model_paused, model}, 15_000

      assert {:ok, [runtime]} =
               ServerManager.runtime_candidates(%{person_id: person.id}, nil, %{
                 agent_id: agent.id
               })

      server = runtime.runtime_pid
      server_ref = Process.monitor(server)
      assert {:ok, status} = Jido.AgentServer.status(server)
      selection = status.raw_state.request_effects
      assert [%{id: selected_id}] = selection.values[AttachDocuments]
      assert selected_id == files.b.id
      refute_received {:delivery_upload, _, _}
      refute_received {:delivery_boundary, _, _, _}

      interrupt_selection(@scenario, server, selection.request_id, files.b, person)
      send(model, :release)

      assert_interrupted_delivery(@scenario, destination, namespace, files.b)
      delivery_event = await_delivery_event(destination.config.id)
      outgoing = delivery_event.request
      Task.await(ingress, 10_000)

      if @scenario == :revoke do
        trace_id = delivery_event.trace_id
        assert_receive {:delivery_failed, ^trace_id, writer}, 10_000
        await_writer(writer)
      end

      if @scenario in [:steer, :privacy], do: await_delivery_writer(destination.config.id)

      if @scenario in [:cancel, :failure] do
        assert outgoing.metadata.error
        assert outgoing.attachments == []
        assert_receive {:DOWN, ^server_ref, :process, ^server, _}, 10_000

        if @provider == :mattermost do
          body = outgoing.body
          assert_receive {:history_update, %{"message" => ^body}}, 10_000
        end
      else
        assert {:ok, status} = Jido.AgentServer.status(server)
        assert status.raw_state.request_effects.request_id == selection.request_id
      end

      if @scenario == :steer do
        assert outgoing.attachments == []
        assert {:ok, status} = Jido.AgentServer.status(server)
        assert status.raw_state.request_effects.values[AttachDocuments] == []
        trace = status.raw_state.__strategy__.request_traces[selection.request_id].events
        assert Enum.any?(trace, &(&1.kind == :input_injected))
        assert Enum.all?(trace, &(&1.request_id == selection.request_id))
        assert_receive {:attachment_model_request, 3, request}, 1_000
        assert inspect(request) =~ "Remove B instead"
      end

      assert_private_history(outgoing, files, root)

      if @scenario == :privacy and @provider == :mattermost do
        message = Repo.get!(Message, outgoing.metadata.assistant_message_id)
        assert [%{"name" => "B.txt", "mime_type" => "text/plain"}] = message.attachments
      end

      refute_received {:delivery_upload, _, _}
      refute_received {:delivery_boundary, _, _, _}

      followup = Map.put(destination, :message_id, "attachment-followup@example.test")
      next_ingress = Task.async(fn -> ingest(followup, "Answer without attachments") end)
      assert_receive {:attachment_model_paused, next_model}, 15_000

      assert {:ok, [next_runtime]} =
               ServerManager.runtime_candidates(%{person_id: person.id}, nil, %{
                 agent_id: agent.id
               })

      assert {:ok, next_status} = Jido.AgentServer.status(next_runtime.runtime_pid)
      refute next_status.raw_state.request_effects.request_id == selection.request_id
      assert next_status.raw_state.request_effects.values[AttachDocuments] == []
      send(next_model, :release)
      assert_delivery(followup, namespace, nil)
      assert await_delivery(destination.config.id).attachments == []
      Task.await(next_ingress, 10_000)
      await_delivery_writer(destination.config.id)
      refute_received {:delivery_upload, _, _}
      refute_received {:delivery_boundary, _, _, _}
    end
  end

  defp interrupted_steps(:failure),
    do: [{:pause, {:tool, "add", []}}, {:http_error, 400}]

  defp interrupted_steps(:steer),
    do: [
      fn request -> {:pause, select_documents(request, "remove", [0])} end,
      {:text, "No files selected."}
    ]

  defp interrupted_steps(_), do: [{:pause, {:text, "Here is B."}}]

  defp interrupt_selection(:cancel, server, request_id, _file, _person),
    do: assert(:ok = Factory.cancel(server, request_id: request_id, reason: :user_cancelled))

  defp interrupt_selection(:steer, server, request_id, _file, _person),
    do:
      assert(
        {:ok, _} = Factory.steer(server, "Remove B instead", expected_request_id: request_id)
      )

  defp interrupt_selection(:revoke, _server, _request_id, file, person) do
    resource = %StorageEntry{id: file.id}
    grant = Enum.find(Permissions.list(resource), &(&1.person_id == person.id))
    assert grant
    assert :ok = Permissions.revoke(resource, grant)
  end

  defp interrupt_selection(_, _server, _request_id, _file, _person), do: :ok

  defp assert_interrupted_delivery(:privacy, destination, namespace, file),
    do: assert_delivery(destination, namespace, file)

  defp assert_interrupted_delivery(:steer, destination, namespace, _file),
    do: assert_delivery(destination, namespace, nil)

  defp assert_interrupted_delivery(:revoke, %{provider: :email}, _namespace, _file) do
    refute_receive {:delivery_boundary, _, _, _}
  end

  defp assert_interrupted_delivery(:revoke, %{provider: :mattermost}, _namespace, _file) do
    assert_receive {:history_update,
                    %{
                      "message" =>
                        "Here is B.\n\nFile delivery failed: The attachment could not be sent."
                    }},
                   10_000
  end

  defp assert_interrupted_delivery(_scenario, %{provider: :mattermost}, _namespace, _file),
    do: :ok

  defp assert_interrupted_delivery(_scenario, %{provider: :email}, namespace, _file) do
    assert_receive {:delivery_boundary, ^namespace, provider, capture}, 10_000
    mail = Mail.parse(capture.raw)
    assert Mail.get_attachments(mail) == []
    assert Mail.get_text(mail).body != ""
    send(provider, :accept_delivery)
  end

  defp assert_private_history(outgoing, files, root) do
    id = outgoing.metadata[:assistant_message_id]
    assert is_binary(id)

    message =
      if outgoing.metadata.error do
        # Failed executions reserve an answer ID but do not persist an assistant answer.
        refute Repo.get(Message, id)
        %{attachments: []}
      else
        message = Repo.get!(Message, id)
        assert message.content == outgoing.body
        message
      end

    persisted =
      Jason.encode!(%{
        history: Map.take(message, [:content, :attachments, :trace, :metadata]),
        visible_steps: ToolStep.project(outgoing.metadata[:tool_calls] || [])
      })

    for private <- [root, files.a.id, files.b.id, files.a.bytes, files.b.bytes, "rt2."] do
      refute persisted =~ private
    end

    for attachment <- message.attachments do
      refute Map.has_key?(attachment, "content")
      refute Map.has_key?(attachment, "materialization_handle")
    end
  end

  defp await_delivery_writer(config_id) do
    assert_receive {:delivery_writer, ^config_id, writer}, 10_000
    await_writer(writer)
  end

  defp await_writer(writer) do
    ref = Process.monitor(writer)
    assert_receive {:DOWN, ^ref, :process, ^writer, reason}, 10_000
    assert reason in [:normal, :noproc]
  end

  defp selection_steps(:remove), do: [&select_documents(&1, "remove", [0])]
  defp selection_steps(:replace), do: [&select_documents(&1, "replace", [2])]

  defp selection_steps(:repeat),
    do: [&select_documents(&1, "add", [2]), &select_documents(&1, "remove", [0])]

  defp selection_steps(:clear), do: [{:tool, "replace", []}]

  defp final_text(:clear), do: "No files selected."
  defp final_text(_), do: "Here is B."

  defp await_delivery(config_id), do: await_delivery_event(config_id).request

  defp await_delivery_event(config_id) do
    receive do
      {:node_router_event,
       %Zaq.Event{opts: opts, request: %Zaq.Engine.Messages.Outgoing{} = outgoing} = event} ->
        if opts[:action] == :deliver_outgoing and
             Map.get(outgoing.routing_context, :channel_config_id) == config_id,
           do: event,
           else: await_delivery_event(config_id)
    after
      10_000 -> flunk("no confirmed Engine delivery event")
    end
  end

  defp get_document(config, id) do
    {:call, "get_document", %{provider: "disk", document_id: id, config_id: to_string(config.id)}}
  end

  defp select_documents(request, operation, indices) do
    results = MultiAgentOpenAIStub.tool_results(request)

    records =
      Enum.map(indices, fn index ->
        result = Enum.find(results, &(&1.call_id == "selection_#{index}"))
        assert is_map(result.output), "document tool must return a structured result"
        assert %{"ok" => true, "result" => %{"record" => record}} = result.output
        record
      end)

    {:tool, operation, records}
  end

  defp documents!(namespace, person) do
    root = Path.join(VolumeConfig.base_path(), namespace)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    disk =
      config!("disk", namespace, %{
        kind: "data_source",
        settings: %{"volumes" => [%{"name" => "documents", "path" => namespace}]}
      })

    {:ok, storage_opts} = VolumeConfig.opts_for_channel_config(disk)

    files =
      Map.new([{:a, "A", "A private bytes"}, {:b, "B", "B selected bytes"}], fn {key, name, bytes} ->
        File.write!(Path.join(root, "#{name}.txt"), bytes)
        {:ok, entry} = Storage.file_info("documents", "#{name}.txt", storage_opts)
        {:ok, _} = Permissions.grant(%StorageEntry{id: entry.id}, %{person_id: person.id})
        {key, %{id: entry.id, name: "#{name}.txt", bytes: bytes}}
      end)

    {disk, files, root}
  end

  defp destination!(provider, namespace, owner, connections \\ 2)

  defp destination!(:mattermost, namespace, owner, _connections) do
    posts = :atomics.new(1, [])

    handler = fn conn, body ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/v4/posts"} ->
          {status, post} = MattermostHistoryFixture.http(conn, body, owner)
          number = :atomics.add_get(posts, 1, 1)
          {status, Map.put(post, "id", post_id(number))}

        {"POST", "/api/v4/files"} ->
          MattermostHistoryFixture.delivery_http(conn, body, owner, namespace)

        {"PUT", "/api/v4/posts/bot-response/patch"} ->
          payload = Jason.decode!(body)
          send(owner, {:delivery_boundary, namespace, self(), %{post: payload}})

          receive do
            :accept_delivery ->
              {200, Map.merge(payload, %{"id" => "bot-response", "user_id" => "bot"})}
          after
            10_000 -> flunk("attachment edit not accepted")
          end

        _ ->
          MattermostHistoryFixture.http(conn, body, owner)
      end
    end

    {child, endpoint} = OpenAIStub.server(handler, owner)
    start_supervised!(Supervisor.child_spec(child, id: make_ref()))

    config =
      config!("mattermost", namespace, %{
        url: String.trim_trailing(endpoint, "/v1"),
        token: "test-token",
        settings: %{"jido_chat" => %{"bot_user_id" => "bot", "bot_name" => "zaq"}}
      })

    on_exit(fn ->
      Zaq.Channels.Supervisor.stop_bridge_runtime(config, "mattermost_#{config.id}")
    end)

    %{provider: :mattermost, config: config, identifier: "alice"}
  end

  defp destination!(:email, namespace, owner, connections) do
    port = FileDeliverySmtpStub.start!(owner, namespace, connections: connections)

    smtp =
      config!("email:smtp", namespace, %{
        url: "smtp://127.0.0.1",
        token: "synthetic-unused",
        settings: %{
          "relay" => "127.0.0.1",
          "port" => to_string(port),
          "tls" => "never",
          "from_email" => "bot@example.test"
        }
      })

    imap =
      config!("email:imap", namespace, %{
        url: "imap://127.0.0.1",
        token: "synthetic-unused",
        settings: %{
          "imap" => %{
            "username" => "bot@example.test",
            "smtp_config_id" => smtp.id,
            "selected_mailboxes" => ["INBOX"]
          }
        }
      })

    %{provider: :email, config: imap, identifier: "sender@example.test"}
  end

  defp post_id(1), do: "bot-response"
  defp post_id(number), do: "bot-response-#{number}"

  defp bind!(destination, person, agent) do
    {:ok, _} =
      People.add_channel(%{
        person_id: person.id,
        platform: to_string(destination.provider),
        channel_identifier: destination.identifier,
        channel_config_id: destination.config.id
      })

    {:ok, _} =
      IncomingMessageRouting.upsert_rule(%{channel_config_id: destination.config.id}, %{
        routing_mode: :agent,
        configured_agent_id: agent.id
      })
  end

  defp ingest(%{provider: :mattermost, config: config} = destination, text) do
    assert {{:ok, _}, _} =
             MattermostHistoryFixture.post(config, "human", true, %{
               "id" => Map.get(destination, :message_id, "incoming-post"),
               "message" => "@zaq " <> text
             })
  end

  defp ingest(%{provider: :email, config: config} = destination, text) do
    assert :ok =
             EmailBridge.from_listener(
               config,
               %{
                 "from" => "sender@example.test",
                 "to" => ["bot@example.test"],
                 "subject" => "Attachment journey",
                 "body_text" => text,
                 "message_id" =>
                   Map.get(destination, :message_id, "attachment-request@example.test"),
                 "in_reply_to" => "attachment-root@example.test"
               },
               adapter: ImapAdapter,
               mailbox: "INBOX"
             )
  end

  defp assert_delivery(%{provider: :mattermost}, _namespace, nil) do
    assert_receive {:history_update, %{"message" => "No files selected."}}, 10_000
    refute_received {:delivery_upload, _, _}
  end

  defp assert_delivery(%{provider: :mattermost}, namespace, file) do
    assert_receive {:delivery_upload, ^namespace, upload}, 10_000
    assert upload.filename == file.name
    assert upload.bytes == file.bytes
    assert upload.mime_type == "text/plain"
    assert upload.channel_id == "shared-room"
    assert_receive {:delivery_boundary, ^namespace, provider, %{post: post}}, 5_000
    assert post["message"] == "Here is B."
    assert post["file_ids"] == ["file-#{namespace}"]
    assert_received {:history_post, placeholder}
    assert placeholder["channel_id"] == "shared-room"
    assert placeholder["root_id"] == "root-human"
    send(provider, :accept_delivery)
  end

  defp assert_delivery(%{provider: :email} = destination, namespace, file) do
    assert_receive {:delivery_boundary, ^namespace, provider, capture}, 10_000
    assert capture.sender == "bot@example.test"
    assert capture.recipients == ["sender@example.test"]
    mail = Mail.parse(capture.raw)

    assert mail.headers["in-reply-to"] ==
             "<#{Map.get(destination, :message_id, "attachment-request@example.test")}>"

    assert Mail.get_attachments(mail) == if(file, do: [{file.name, file.bytes}], else: [])

    if file do
      assert [attachment] = Enum.filter(mail.parts, &MailMessage.is_attachment?/1)
      # gen_smtp omits Content-Type for the MIME default, text/plain US-ASCII.
      content_type = MailMessage.get_header(attachment, :content_type) || ["text/plain"]
      assert ["text/plain" | _] = content_type
    end

    assert Mail.get_text(mail).body == if(file, do: "Here is B.", else: "No files selected.")
    send(provider, :accept_delivery)
  end

  defp config!(provider, namespace, attrs) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(
      Map.merge(
        %{name: "#{provider}-#{namespace}", provider: provider, kind: "retrieval", enabled: true},
        attrs
      )
    )
    |> Repo.insert!()
  end
end
