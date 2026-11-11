defmodule Zaq.Channels.AttachmentAgentJourneyTest do
  use Zaq.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Zaq.TestSupport.ChannelFileFixtures, only: [config!: 3]
  import Zaq.TestSupport.MattermostHistoryFixture, only: [assert_uploaded_file: 4]

  @endpoint ZaqWeb.Endpoint

  alias Mail.Message, as: MailMessage
  alias Zaq.Accounts.People
  alias Zaq.Agent.{Factory, ServerManager}
  alias Zaq.Channels.EmailBridge
  alias Zaq.Channels.EmailBridge.ImapAdapter
  alias Zaq.Contracts.ToolStep
  alias Zaq.Engine.{ChannelConfig, IncomingMessageRouting}
  alias Zaq.Engine.Conversations.Message
  alias Zaq.Engine.Notifications
  alias Zaq.Engine.Notifications.NotificationLog
  alias Zaq.Engine.Workflows
  alias Zaq.Permissions
  alias Zaq.Storage
  alias Zaq.Storage.{StorageEntry, VolumeConfig}

  alias Zaq.TestSupport.{
    AttachmentSelectionLLMStub,
    ChannelFileFixtures,
    IntegrationAgent,
    MattermostHistoryFixture,
    MultiAgentOpenAIStub
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

  for provider <- [:mattermost, :email] do
    @tag :workflow_attachment
    test "workflow RunAgent selects a document and NotifyPerson delivers it through #{provider}" do
      provider = unquote(provider)

      stub(Zaq.NodeRouterMock, :dispatch, fn
        %Zaq.Event{name: :workflow} = event -> event
        %Zaq.Event{request: {:broadcast, "workflow:" <> _, _}} = event -> event
        %Zaq.Event{request: {:broadcast, "workflow_run:" <> _, _}} = event -> event
      end)

      owner = self()
      namespace = "workflow-attachment-#{Ecto.UUID.generate()}"
      {:ok, person} = People.create_person(%{full_name: namespace})
      {disk, files, root} = documents!(namespace, person)
      destination = workflow_destination!(provider, namespace, owner)

      {:ok, _} =
        People.add_channel(%{
          person_id: person.id,
          platform: to_string(provider),
          channel_identifier: destination.identifier,
          channel_config_id: destination.config.id
        })

      {child, endpoint} =
        AttachmentSelectionLLMStub.server(
          [
            get_document(disk, files.b.id),
            &select_documents(&1, "add", [0]),
            {:text, "Here is B."}
          ],
          owner
        )

      start_supervised!(child)

      agent =
        IntegrationAgent.create!(endpoint, namespace, "Retrieve B and attach it to the answer.", [
          "data_source.get_document",
          "data_source.attach_document"
        ])

      on_exit(fn -> ServerManager.stop_server(agent) end)

      {run, execution} = start_file_workflow!(namespace, person, agent)

      try do
        capture = await_workflow_delivery(execution, namespace, run.id)
        assert {:ok, completed} = Task.await(execution, 15_000)
        assert completed.status == "completed"

        steps = Map.new(Workflows.list_step_runs(run.id), &{&1.step_name, &1})
        assert steps["select_document"].status == "completed"
        assert steps["send_file"].status == "completed"
        assert steps["send_file"].results["notified"] == true

        assert_received {:attachment_model_request, 2, request}

        assert [%{output: loaded}, %{output: selected}] =
                 MultiAgentOpenAIStub.tool_results(request)

        assert %{"ok" => true, "result" => %{"record" => record}} = loaded

        assert %{"ok" => true, "result" => %{"operation" => "add", "records" => [^record]}} =
                 selected

        assert_workflow_file(provider, capture, namespace, destination, files.b)
        assert File.read!(Path.join(root, files.b.name)) == files.b.bytes
        assert File.read!(Path.join(root, files.a.name)) == files.a.bytes
        refute_received {:llm_stub_error, _}
      after
        Task.shutdown(execution, :brutal_kill)
      end
    end
  end

  for {label, attempts} <- [
        {"email strict", [{:email, false}]},
        {"email continue", [{:email, true}]},
        {"email default", [{:email, :missing}]},
        {"Mattermost strict", [{:mattermost, false}]},
        {"Mattermost continue", [{:mattermost, true}]},
        {"Mattermost default", [{:mattermost, :missing}]},
        {"strict Mattermost then permissive email", [{:mattermost, false}, {:email, true}]},
        {"strict email then strict Mattermost", [{:email, false}, {:mattermost, false}]}
      ] do
    @tag :workflow_policy
    test "workflow notification records and renders #{label} attachment delivery" do
      attempts = unquote(Macro.escape(attempts))

      stub(Zaq.NodeRouterMock, :dispatch, fn
        %Zaq.Event{name: :workflow} = event -> event
        %Zaq.Event{request: {:broadcast, "workflow:" <> _, _}} = event -> event
        %Zaq.Event{request: {:broadcast, "workflow_run:" <> _, _}} = event -> event
      end)

      namespace = "workflow-policy-#{Ecto.UUID.generate()}"
      {:ok, person} = People.create_person(%{full_name: namespace})
      {disk, files, root} = documents!(namespace, person)

      destinations =
        for {{provider, policy}, weight} <- Enum.with_index(attempts) do
          destination = workflow_destination!(provider, namespace, self())

          settings =
            if policy == :missing,
              do: Map.delete(destination.config.settings, "send_on_file_failure"),
              else: Map.put(destination.config.settings, "send_on_file_failure", policy)

          {:ok, config} =
            destination.config |> ChannelConfig.changeset(%{settings: settings}) |> Repo.update()

          {:ok, _} =
            People.add_channel(%{
              person_id: person.id,
              platform: to_string(provider),
              channel_identifier: destination.identifier,
              channel_config_id: config.id,
              weight: weight
            })

          Map.merge(destination, %{config: config, provider: provider, policy: policy})
        end

      {child, endpoint} =
        AttachmentSelectionLLMStub.server(
          [
            get_document(disk, files.a.id),
            &select_documents(&1, "add", [0]),
            get_document(disk, files.b.id),
            &select_documents(&1, "add", [2]),
            {:pause, {:text, "Here is B."}}
          ],
          self()
        )

      start_supervised!(child)

      agent =
        IntegrationAgent.create!(endpoint, namespace, "Select both requested documents.", [
          "data_source.get_document",
          "data_source.attach_document"
        ])

      on_exit(fn -> ServerManager.stop_server(agent) end)
      {run, execution} = start_file_workflow!(namespace, person, agent)

      try do
        assert_receive {:attachment_model_paused, model}, 15_000
        interrupt_selection(:revoke, nil, nil, files.b, person)
        send(model, :release)
        winner = Enum.find(destinations, &(&1.policy != false))

        capture =
          if winner do
            capture = await_workflow_delivery(execution, namespace, run.id)
            assert_workflow_file(winner.provider, capture, namespace, winner, files.a)
            assert {:ok, completed} = Task.await(execution, 15_000)
            assert completed.status == "completed"
            capture
          else
            assert {:ok, failed} = Task.await(execution, 15_000)
            assert failed.status == "failed"
            assert failed.log_summary.failed_steps == ["send_file"]
            nil
          end

        steps = Map.new(Workflows.list_step_runs(run.id), &{&1.step_name, &1})
        assert steps["select_document"].status == "completed"
        assert steps["send_file"].status == if(winner, do: "completed", else: "failed")

        if winner do
          assert steps["send_file"].results["notified"] == true
        else
          assert inspect(steps["send_file"].errors) =~ "all_channels_failed"
          assert Repo.get!(Zaq.Engine.Workflows.WorkflowRun, run.id).status == "failed"
        end

        selected = steps["select_document"].results["attachments"]
        assert Enum.map(selected, & &1["id"]) == [files.a.id, files.b.id]
        refute inspect(selected) =~ files.a.bytes
        refute inspect(selected) =~ files.b.bytes

        log = Repo.one!(from(log in NotificationLog, where: log.recipient_name == ^namespace))
        assert log.status == if(winner, do: "sent", else: "failed")

        assert log.payload == %{
                 "subject" => namespace,
                 "body" => "Here is B.",
                 "html_body" => nil
               }

        assert Enum.map(log.channels_tried, & &1["platform"]) ==
                 Enum.map(destinations, &to_string(&1.provider))

        for {attempt, destination} <- Enum.zip(log.channels_tried, destinations) do
          assert attempt["identifier"] == destination.identifier

          if destination.policy == false do
            assert attempt["status"] == "error"
            assert attempt["error"] =~ "not_sent"
            assert attempt["error"] =~ "preparation"
            refute attempt["error"] =~ files.b.id
            refute attempt["error"] =~ "materialization"
          else
            assert attempt["status"] == "ok"
            assert attempt["error"] == nil
          end
        end

        if winner && winner.provider == :email do
          assert is_binary(log.threading["message_id"])
          assert log.threading["message_id"] == steps["send_file"].results["message_id"]

          assert Mail.parse(capture.raw).headers["message-id"] ==
                   "<#{log.threading["message_id"]}>"

          assert log.thread_key == namespace
        else
          assert is_nil(log.threading)
        end

        refute_received {:delivery_boundary, ^namespace, _, _}
        refute_received {:delivery_upload, ^namespace, _}
        assert File.read!(Path.join(root, files.a.name)) == files.a.bytes
        assert File.read!(Path.join(root, files.b.name)) == files.b.bytes
        assert_notification_center(log)
        refute_received {:llm_stub_error, _}
      after
        Task.shutdown(execution, :brutal_kill)
      end
    end
  end

  defp assert_notification_center(log) do
    stub(Zaq.NodeRouterMock, :find_node, fn _ -> :channels@localhost end)
    user = user_fixture()
    {:ok, user} = Zaq.Accounts.change_password(user, %{password: "StrongPass1!"})
    conn = build_conn() |> init_test_session(%{user_id: user.id})
    {:ok, view, _html} = live(conn, "/bo/channels/notifications/logs")
    assert has_element?(view, "#log-#{log.id}", log.status)

    html = view |> element("#log-#{log.id} button[phx-click=view_log]") |> render_click()
    assert html =~ "Notification Details"
    assert html =~ log.payload["subject"]
    assert html =~ log.payload["body"]

    for attempt <- log.channels_tried do
      assert html =~ attempt["platform"]

      if attempt["error"],
        do:
          assert(
            html =~ Phoenix.HTML.html_escape(attempt["error"]) |> Phoenix.HTML.safe_to_string()
          )
    end

    assert has_element?(view, "#log-#{log.id}", if(log.status == "sent", do: "✓", else: "✗"))
    refute html =~ "B selected bytes"
  end

  defp start_file_workflow!(namespace, person, agent) do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: namespace,
        status: "active",
        nodes: [
          %{
            name: "select_document",
            type: "action",
            module: "Zaq.Agent.Tools.Workflow.RunAgent",
            params: %{"agent_id" => agent.id, "input" => "Retrieve B and attach it."},
            index: 0
          },
          %{
            name: "send_file",
            type: "action",
            module: "Zaq.Agent.Tools.People.NotifyPerson",
            params: %{"person" => %{"id" => person.id}, "subject" => namespace},
            index: 1
          }
        ],
        edges: [
          %{
            from: "select_document",
            to: "send_file",
            mapping: %{"message" => "output", "attachments" => "attachments"}
          }
        ]
      })

    {:ok, run} =
      Workflows.create_run(workflow, %{
        "actor" => %{person_id: person.id},
        "request" => nil,
        "assigns" => %{}
      })

    {run, Task.async(fn -> Workflows.start_run(run) end)}
  end

  defp await_workflow_delivery(execution, namespace, run_id) do
    ref = execution.ref

    receive do
      {:delivery_boundary, ^namespace, transport, capture} ->
        send(transport, :accept_delivery)
        capture

      {^ref, result} ->
        flunk(
          "Workflow finished without reaching delivery: #{inspect(result)}; " <>
            "steps: #{inspect(Workflows.list_step_runs(run_id))}"
        )
    after
      20_000 -> flunk("Workflow did not reach the #{namespace} transport")
    end
  end

  for provider <- [:mattermost, :email], denial <- [:revoked, :missing_actor] do
    @tag :workflow_attachment
    @tag provider: provider, denial: denial
    test "#{provider} notification cannot deliver selected files with #{denial} source access", %{
      provider: provider,
      denial: denial
    } do
      namespace = "denied-attachment-#{Ecto.UUID.generate()}"
      {:ok, person} = People.create_person(%{full_name: namespace})
      {disk, files, _root} = documents!(namespace, person)
      destination = workflow_destination!(provider, namespace, self())
      actor = %{person_id: person.id}

      {:ok, _} =
        People.add_channel(%{
          person_id: person.id,
          platform: to_string(provider),
          channel_identifier: destination.identifier,
          channel_config_id: destination.config.id
        })

      assert {:ok, %{record: record}} =
               Jido.Exec.run(
                 Zaq.Agent.Tools.DataSource.GetDocument,
                 %{provider: "disk", document_id: files.b.id, config_id: to_string(disk.id)},
                 %{actor: actor},
                 timeout: 0
               )

      if denial == :revoked do
        resource = %StorageEntry{id: files.b.id}
        grant = Enum.find(Permissions.list(resource), &(&1.person_id == person.id))
        assert :ok = Permissions.revoke(resource, grant)
      end

      execution =
        Task.async(fn ->
          Notifications.notify_person(
            person.id,
            %{subject: namespace, message: "Here is B.", attachments: [record]},
            trusted_context: %{actor: if(denial == :revoked, do: actor)}
          )
        end)

      try do
        assert_receive {:delivery_boundary, ^namespace, transport, capture}, 10_000
        send(transport, :accept_delivery)
        assert {:ok, %{status: :sent, notification_log_id: log_id}} = Task.await(execution)

        if provider == :mattermost do
          refute capture.post["file_ids"]
          assert capture.post["message"] == "Here is B."
        else
          mail = Mail.parse(capture.raw)
          assert Mail.get_attachments(mail) == []
          assert Mail.get_text(mail).body == "Here is B."
        end

        refute_received {:delivery_upload, ^namespace, _}
        log = Repo.get!(NotificationLog, log_id)
        assert log.status == "sent"
        assert [%{"status" => "ok", "error" => nil}] = log.channels_tried

        assert log.payload == %{
                 "subject" => namespace,
                 "body" => "Here is B.",
                 "html_body" => nil
               }
      after
        Task.shutdown(execution, :brutal_kill)
      end
    end
  end

  defp assert_workflow_file(:mattermost, capture, namespace, destination, file) do
    assert capture.post["message"] == "Here is B."
    assert capture.post["channel_id"] == destination.identifier
    assert capture.post["file_ids"] == ["file-#{namespace}"]
    assert_received {:delivery_upload, ^namespace, upload}
    assert_uploaded_file(upload, file.name, "text/plain", file.bytes)
    assert upload.channel_id == destination.identifier
  end

  defp assert_workflow_file(:email, capture, _namespace, destination, file) do
    assert capture.sender == "bot@example.test"
    assert capture.recipients == [destination.identifier]
    mail = Mail.parse(capture.raw)
    assert Mail.get_text(mail).body == "Here is B."
    assert Mail.get_attachments(mail) == [{file.name, file.bytes}]
  end

  defp workflow_destination!(:mattermost, namespace, owner) do
    handler = &MattermostHistoryFixture.delivery_http(&1, &2, owner, namespace)

    config =
      ChannelFileFixtures.mattermost!(owner, namespace, handler, %{
        token: "test-token",
        settings: %{"max_file_size" => 307_200}
      })

    %{config: config, identifier: "workflow-room"}
  end

  defp workflow_destination!(:email, namespace, owner) do
    destination = destination!(:email, namespace, owner, 1)
    smtp = Repo.get!(ChannelConfig, destination.config.settings["imap"]["smtp_config_id"])
    %{config: smtp, identifier: destination.identifier}
  end

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

      agent =
        start_conversation_agent!(script ++ [{:pause, {:text, "No files selected."}}], namespace)

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
      destination = destination!(@provider, namespace, self(), 2)

      script =
        [get_document(disk, files.b.id), &select_documents(&1, "add", [0])] ++
          interrupted_steps(@scenario) ++ [{:pause, {:text, "No files selected."}}]

      agent = start_conversation_agent!(script, namespace)
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
      selection = %{request_id: status.raw_state.last_request_id}

      completion =
        Enum.find(
          status.raw_state.__strategy__.request_traces[selection.request_id].events,
          &(&1.kind == :tool_completed and &1.tool_name == "attach_documents")
        )

      assert {:ok, %{operation: "add", records: [%{"id" => selected_id}]}, []} =
               completion.data.result

      assert selected_id == files.b.id
      refute Map.has_key?(status.raw_state, :request_effects)
      refute_received {:delivery_upload, _, _}
      refute_received {:delivery_boundary, _, _, _}

      interrupt_selection(@scenario, server, selection.request_id, files.b, person)
      send(model, :release)

      assert_interrupted_delivery(@scenario, destination, namespace, files.b)
      delivery_event = await_delivery_event(destination.config.id)
      outgoing = delivery_event.request
      Task.await(ingress, 10_000)

      if @scenario in [:revoke, :steer, :privacy],
        do: await_delivery_writer(destination.config.id)

      if @scenario == :revoke do
        message = Repo.get!(Message, outgoing.metadata.assistant_message_id)
        assert message.content == "Here is B."

        assert message.metadata["delivery_confirmation"]["channel_config_id"] ==
                 destination.config.id
      end

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
        assert status.raw_state.last_request_id == selection.request_id
      end

      if @scenario == :steer do
        assert outgoing.attachments == []
        assert {:ok, status} = Jido.AgentServer.status(server)
        refute Map.has_key?(status.raw_state, :request_effects)
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
      refute next_status.raw_state.last_request_id == selection.request_id
      refute Map.has_key?(next_status.raw_state, :request_effects)
      send(next_model, :release)
      assert_delivery(followup, namespace, nil)
      assert await_delivery(destination.config.id).attachments == []
      Task.await(next_ingress, 10_000)
      await_delivery_writer(destination.config.id)
      refute_received {:delivery_upload, _, _}
      refute_received {:delivery_boundary, _, _, _}
    end
  end

  defp start_conversation_agent!(script, namespace) do
    {child, endpoint} = AttachmentSelectionLLMStub.server(script, self())
    start_supervised!(child)

    agent =
      IntegrationAgent.create!(endpoint, namespace, "Select the requested files.", [
        "data_source.get_document",
        "data_source.attach_document"
      ])

    {:ok, agent} = Zaq.Agent.update_agent(agent, %{conversation_enabled: true})
    on_exit(fn -> ServerManager.stop_server(agent) end)
    agent
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

  defp assert_interrupted_delivery(:revoke, %{provider: :email}, namespace, _file) do
    assert_receive {:delivery_boundary, ^namespace, provider, capture}, 10_000
    mail = Mail.parse(capture.raw)
    assert Mail.get_attachments(mail) == []
    assert Mail.get_text(mail).body == "Here is B."
    send(provider, :accept_delivery)
  end

  defp assert_interrupted_delivery(:revoke, %{provider: :mattermost}, _namespace, _file) do
    assert_receive {:history_update, %{"message" => "Here is B."}}, 10_000
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
        history:
          message
          |> Map.take([:content, :attachments, :metadata])
          |> Map.put(:trace, ToolStep.from_trace(Map.get(message, :trace))),
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
    files = [
      %{name: "A.txt", bytes: "A private bytes"},
      %{name: "B.txt", bytes: "B selected bytes"}
    ]

    {disk, root} = ChannelFileFixtures.disk_files!(namespace, "documents", files)

    {:ok, storage_opts} = VolumeConfig.opts_for_channel_config(disk)

    files =
      Map.new(Enum.zip([:a, :b], files), fn {key, file} ->
        {:ok, entry} = Storage.file_info("documents", file.name, storage_opts)
        {:ok, _} = Permissions.grant(%StorageEntry{id: entry.id}, %{person_id: person.id})
        {key, Map.put(file, :id, entry.id)}
      end)

    {disk, files, root}
  end

  defp attachment_edit_response(%{"file_ids" => _} = payload, _conn, _body, owner, namespace) do
    send(owner, {:delivery_boundary, namespace, self(), %{post: payload}})

    receive do
      :accept_delivery ->
        {200, Map.merge(payload, %{"id" => "bot-response", "user_id" => "bot"})}
    after
      10_000 -> flunk("attachment edit not accepted")
    end
  end

  defp attachment_edit_response(_payload, conn, body, owner, _namespace),
    do: MattermostHistoryFixture.http(conn, body, owner)

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

        {"PUT", "/api/v4/posts/bot-response"} ->
          attachment_edit_response(Jason.decode!(body), conn, body, owner, namespace)

        _ ->
          MattermostHistoryFixture.http(conn, body, owner)
      end
    end

    config =
      ChannelFileFixtures.mattermost!(owner, namespace, handler, %{
        token: "test-token",
        settings: %{
          "max_file_size" => 307_200,
          "jido_chat" => %{"bot_user_id" => "bot", "bot_name" => "zaq"}
        }
      })

    on_exit(fn ->
      Zaq.Channels.Supervisor.stop_bridge_runtime(config, "mattermost_#{config.id}")
    end)

    %{provider: :mattermost, config: config, identifier: "alice"}
  end

  defp destination!(:email, namespace, owner, connections) do
    smtp =
      ChannelFileFixtures.smtp!(owner, namespace, %{"from_email" => "bot@example.test"},
        connections: connections
      )

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
    assert_uploaded_file(upload, file.name, "text/plain", file.bytes)
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
end
