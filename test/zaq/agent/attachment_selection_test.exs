defmodule Zaq.Agent.AttachmentSelectionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Agent.RequestEffects
  alias Zaq.Agent.Tools.DataSource.AttachDocuments
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance

  property "ordered mutations deduplicate, remove absent records and replace atomically" do
    check all(
            operations <-
              list_of(
                tuple(
                  {member_of(["add", "remove", "replace"]), list_of(integer(1..8), max_length: 8)}
                ),
                max_length: 40
              )
          ) do
      {selection, expected} =
        operations
        |> Enum.with_index(1)
        |> Enum.reduce({RequestEffects.new("r", self(), [AttachDocuments]), []}, fn {{op, ids},
                                                                                     seq},
                                                                                    {selection,
                                                                                     expected} ->
          records = Enum.map(ids, &record(to_string(&1)))

          command = %{
            request_id: "r",
            incarnation: self(),
            invocation_id: "call#{seq}",
            handler: AttachDocuments,
            payload: %{operation: op, records: records}
          }

          {:ok, updated} = RequestEffects.apply_command(selection, command)

          expected =
            case op do
              "add" -> Enum.uniq(expected ++ ids)
              "remove" -> expected -- ids
              "replace" -> Enum.uniq(ids)
            end

          assert Enum.map(updated.values[AttachDocuments], &String.to_integer(&1.id)) == expected
          {updated, expected}
        end)

      assert length(selection.values[AttachDocuments]) == length(expected)
    end
  end

  test "replay after removal, foreign requests/incarnations and terminal commands cannot mutate" do
    selection = RequestEffects.new("r", self(), [AttachDocuments])
    a = record("a")

    add = %{
      request_id: "r",
      incarnation: self(),
      invocation_id: "add",
      handler: AttachDocuments,
      payload: %{operation: "add", records: [a]}
    }

    assert {:ok, selection} = RequestEffects.apply_command(selection, add)

    assert {:ok, selection} =
             RequestEffects.apply_command(selection, %{
               add
               | payload: %{operation: "remove", records: [a]},
                 invocation_id: "remove"
             })

    assert {:ok, ^selection} = RequestEffects.apply_command(selection, add)
    assert selection.values[AttachDocuments] == []

    for command <- [%{add | request_id: "other"}, %{add | incarnation: spawn(fn -> :ok end)}] do
      assert {:error, _} = RequestEffects.apply_command(selection, command)
    end

    frozen = RequestEffects.finish(selection, :completed)
    assert {:error, _} = RequestEffects.apply_command(frozen, add)

    assert RequestEffects.finish(%{selection | values: %{AttachDocuments => [a]}}, :failed).values[
             AttachDocuments
           ] == []

    assert RequestEffects.new("next", self(), [AttachDocuments]).values[AttachDocuments] == []
  end

  test "one provider-scoped identity is selected once even with fresh signed projections" do
    selection = RequestEffects.new("r", self(), [AttachDocuments])

    records = [
      record("a", %{"provider" => "disk", "config_id" => 1}, "first"),
      record("a", %{"provider" => "disk", "config_id" => 1}, "second"),
      record("a", %{"provider" => "disk", "config_id" => 2}),
      record("a", %{"provider" => "other", "config_id" => 1})
    ]

    assert Enum.all?(records, &match?({:ok, _}, Provenance.verify(&1)))
    assert Enum.at(records, 0).provenance_ref != Enum.at(records, 1).provenance_ref

    command = %{
      request_id: "r",
      incarnation: self(),
      invocation_id: "add",
      handler: AttachDocuments,
      payload: %{operation: "add", records: records}
    }

    assert {:ok, selection} = RequestEffects.apply_command(selection, command)

    assert selection.values[AttachDocuments] == [
             Enum.at(records, 0),
             Enum.at(records, 2),
             Enum.at(records, 3)
           ]
  end

  defp record(id, claims \\ %{}, parent_id \\ "root") do
    {:ok, record} = Provenance.seal(%Record{id: id, kind: :file, parent_id: parent_id}, claims)
    record
  end
end

defmodule Zaq.Agent.AttachmentSelectionStreamTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.RequestEffects
  alias Zaq.Agent.StreamEvents
  alias Zaq.Agent.Tools.DataSource.AttachDocuments
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Incoming

  test "only the matching runtime/request snapshot reaches a successful final result" do
    record = %Record{id: "a", kind: :file}
    incoming = %Incoming{content: "select", channel_id: "c", provider: :web, message_id: "r"}
    completed = %{kind: :request_completed, data: %{result: "Done"}}
    snapshot = {RequestEffects, "r", self(), %{AttachDocuments => [record]}}

    send(self(), snapshot)

    assert {:ok, %{attachments: [^record]}} =
             StreamEvents.consume([completed], incoming, runtime_pid: self())

    refute_received ^snapshot

    foreign = {RequestEffects, "other", self(), %{AttachDocuments => [record]}}
    send(self(), foreign)

    assert {:ok, %{attachments: []}} =
             StreamEvents.consume([completed], incoming, runtime_pid: self())

    assert_receive ^foreign

    send(self(), snapshot)

    assert {:ok, %{attachments: []}} =
             StreamEvents.consume([completed], incoming, runtime_pid: nil)

    assert_receive ^snapshot

    send(self(), snapshot)

    assert {:ok, %{attachments: []}} =
             StreamEvents.consume([], incoming, runtime_pid: self())

    assert_receive ^snapshot

    for kind <- [:request_failed, :request_cancelled] do
      send(self(), snapshot)

      assert {:error, _, %{attachments: []}} =
               StreamEvents.consume([%{kind: kind, data: %{error: :failed}}], incoming,
                 runtime_pid: self()
               )

      refute_received ^snapshot
    end
  end
end

defmodule Zaq.Agent.AttachmentSelectionRuntimeTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.{Factory, ServerManager, StreamEvents}
  alias Zaq.Agent.Tools.DataSource.AttachDocuments
  alias Zaq.Contracts.{Record, ToolStep}
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.TestSupport.{AttachmentSelectionLLMStub, IntegrationAgent}

  test "requests without the tool retain native events and do not create selection state" do
    {server, configured} = runtime([{:text, "First"}, {:text, "Second"}], [])

    for query <- ["first", "second"] do
      {request, events} = ask(server, configured, query)
      observed = Enum.to_list(events)

      assert {:ok, result} =
               StreamEvents.consume(observed, incoming(), request: request, runtime_pid: server)

      assert result.attachments == []
      assert {:ok, status} = Jido.AgentServer.status(server)
      refute Map.has_key?(status.raw_state, :request_effects)
      assert Enum.any?(observed, &(&1.kind == :checkpoint and is_binary(&1.data[:token])))
    end
  end

  test "real tool iterations retain only B, freeze selection and keep Records out of traces/history" do
    a = record("private-a")
    b = record("private-b")

    {server, configured} =
      runtime([
        {:tool, "add", [Record.metadata(a)]},
        {:tool, "add", [Record.metadata(b)]},
        {:tool, "remove", [Record.metadata(a)]},
        {:text, "Here is B."}
      ])

    {request, events} = ask(server, configured, "Select A, add B, then remove A")
    observed = Enum.to_list(events)

    assert {:ok, result} =
             StreamEvents.consume(observed, incoming(), request: request, runtime_pid: server)

    assert [%Record{id: "private-b"}] = result.attachments
    assert result.answer == "Here is B."
    assert {:ok, status} = Jido.AgentServer.status(server)
    assert status.raw_state.request_effects.status == :completed
    assert Enum.all?(observed, &(&1.request_id == request.id))
    assert Enum.count(observed, &(&1.kind == :tool_completed)) == 3

    refute Enum.any?(observed, &Map.has_key?(&1.data, :request_effects))
    sequences = Enum.map(observed, & &1.seq)
    assert sequences == Enum.to_list(hd(sequences)..List.last(sequences))

    projected =
      inspect(
        {result.trace, result.trace_artifacts, ToolStep.project(result.tool_calls),
         status.raw_state.__strategy__.request_traces, status.raw_state[:__thread__]},
        limit: :infinity
      )

    for value <- [
          a.id,
          b.id,
          a.provenance_ref,
          b.provenance_ref,
          "request_effect",
          "rt2."
        ] do
      refute projected =~ value
    end
  end

  test "parallel conflicting commands apply in declaration order, replacement and empty clear are exact" do
    a = record("a") |> Record.metadata()
    b = record("b") |> Record.metadata()

    {server, configured} =
      runtime([
        {:tools, [{"add", [a]}, {"add", [b]}, {"remove", [a]}]},
        {:tool, "replace", [a]},
        {:tool, "replace", []},
        {:text, "Cleared."}
      ])

    {request, events} = ask(server, configured, "Revise selection")

    assert {:ok, result} =
             StreamEvents.consume(events, incoming(), request: request, runtime_pid: server)

    assert result.attachments == []
    assert {:ok, status} = Jido.AgentServer.status(server)
    assert MapSet.size(status.raw_state.request_effects.seen) == 5
  end

  test "shared-snapshot calls preserve first projection and same-batch remove/add ordering" do
    first = record("a")
    {:ok, fresh} = Provenance.seal(%{first | parent_id: "fresh-projection"})
    a = Record.metadata(first)
    b = Record.metadata(record("b"))

    {server, configured} =
      runtime([
        {:tools, [{"add", [a]}, {"add", [Record.metadata(fresh)]}]},
        {:pause, {:tools, [{"remove", [a]}, {"add", [b]}, {"add", [a]}]}},
        {:text, "Reordered."}
      ])

    {request, events} = ask(server, configured, "Select and reorder")
    assert_receive {:attachment_model_paused, model_pid}, 5_000
    assert {:ok, status} = Jido.AgentServer.status(server)

    assert [%Record{id: "a", parent_id: "root"}] =
             status.raw_state.request_effects.values[AttachDocuments]

    send(model_pid, :release)

    assert {:ok, result} =
             StreamEvents.consume(events, incoming(), request: request, runtime_pid: server)

    assert [%Record{id: "b"}, %Record{id: "a", parent_id: "root"}] = result.attachments
  end

  test "active steering removes a selected file within the same request" do
    a = record("a") |> Record.metadata()

    {server, configured} =
      runtime([{:tool, "add", [a]}, {:pause, {:tool, "remove", [a]}}, {:text, "Removed."}])

    {request, events} = ask(server, configured, "Attach A")
    assert_receive {:attachment_model_paused, model_pid}, 5_000
    assert {:ok, status} = Jido.AgentServer.status(server)
    assert [%Record{id: "a"}] = status.raw_state.request_effects.values[AttachDocuments]

    {busy_request, busy_events} = ask(server, configured, "Another request")

    assert {:error, _, %{attachments: []}} =
             StreamEvents.consume(busy_events, incoming(),
               request: busy_request,
               runtime_pid: server
             )

    assert {:ok, status} = Jido.AgentServer.status(server)
    assert status.raw_state.request_effects.request_id == request.id
    assert [%Record{id: "a"}] = status.raw_state.request_effects.values[AttachDocuments]
    assert {:ok, _} = Factory.steer(server, "Remove A instead", expected_request_id: request.id)
    send(model_pid, :release)

    assert {:ok, _} =
             Jido.AgentServer.await_completion(server,
               status_path: [:__strategy__, :status],
               timeout: 5_000
             )

    observed = Enum.to_list(events)
    assert Enum.any?(observed, &(&1.kind == :input_injected))
    assert Enum.all?(observed, &(&1.request_id == request.id))

    assert {:ok, %{attachments: []}} =
             StreamEvents.consume(observed, incoming(), request: request, runtime_pid: server)
  end

  test "cancellation discards selected files and the next request starts empty" do
    a = record("a") |> Record.metadata()

    {server, configured} =
      runtime([{:tool, "add", [a]}, {:pause, {:text, "Too late."}}, {:text, "Fresh."}])

    {request, events} = ask(server, configured, "Attach A")
    assert_receive {:attachment_model_paused, model_pid}, 5_000
    assert {:ok, status} = Jido.AgentServer.status(server)
    pending_ref = Process.monitor(status.raw_state.__strategy__.pending_input_server)
    assert :ok = Factory.cancel(server, request_id: request.id, reason: :user_cancelled)

    assert {:error, _, %{attachments: []}} =
             StreamEvents.consume(events, incoming(), request: request, runtime_pid: server)

    send(model_pid, :release)
    assert_receive {:DOWN, ^pending_ref, :process, _, _}, 5_000
    assert {:ok, status} = Jido.AgentServer.status(server)
    assert status.raw_state.request_effects.values[AttachDocuments] == []
    {request, events} = ask(server, configured, "New request")

    assert {:ok, %{attachments: [], answer: "Fresh."}} =
             StreamEvents.consume(events, incoming(), request: request, runtime_pid: server)
  end

  test "replayed, cross-request and post-terminal worker events cannot resurrect selection" do
    a = record("a") |> Record.metadata()

    {server, configured} =
      runtime([{:tool, "add", [a]}, {:tool, "remove", [a]}, {:pause, {:text, "Done."}}])

    {request, events} = ask(server, configured, "Revise")
    assert_receive {:attachment_model_paused, model_pid}, 5_000
    assert {:ok, status} = Jido.AgentServer.status(server)
    selection = status.raw_state.request_effects
    assert selection.values[AttachDocuments] == []
    # Native traces have already had private effects stripped; replaying their
    # completion cannot reintroduce a Record or mutate a different request.
    trace = status.raw_state.__strategy__.request_traces[request.id].events
    completion = Enum.find(trace, &(&1.kind == :tool_completed))

    assert {:ok, _} =
             Jido.AgentServer.call(
               server,
               Jido.Signal.new!("ai.react.worker.event", %{
                 event: completion,
                 request_id: request.id
               })
             )

    assert {:ok, status} = Jido.AgentServer.status(server)
    assert status.raw_state.request_effects == selection

    command = %{
      request_id: request.id,
      incarnation: server,
      invocation_id: "selection_0",
      handler: AttachDocuments,
      payload: %{operation: "add", records: [record("a")]}
    }

    effect = %Jido.Agent.StateOp.SetPath{path: [:request_effect], value: command}

    replay = %{
      completion
      | seq: selection.last_seq + 1,
        data:
          Map.put(completion.data, :result, {:ok, %{records: command.payload.records}, [effect]})
    }

    assert {:ok, _} =
             Jido.AgentServer.call(
               server,
               Jido.Signal.new!("ai.react.worker.event", %{event: replay, request_id: request.id})
             )

    assert {:ok, status} = Jido.AgentServer.status(server)
    assert status.raw_state.request_effects.values[AttachDocuments] == []

    foreign = %{replay | request_id: "foreign", seq: replay.seq + 1}

    assert {:ok, _} =
             Jido.AgentServer.call(
               server,
               Jido.Signal.new!("ai.react.worker.event", %{event: foreign, request_id: "foreign"})
             )

    assert {:ok, status} = Jido.AgentServer.status(server)
    assert status.raw_state.request_effects.request_id == request.id
    send(model_pid, :release)
    observed = Enum.to_list(events)

    assert {:ok, %{attachments: []}} =
             StreamEvents.consume(observed, incoming(), request: request, runtime_pid: server)

    assert {:ok, _} =
             Jido.AgentServer.call(
               server,
               Jido.Signal.new!("ai.react.worker.event", %{
                 event: %{completion | seq: completion.seq + 100},
                 request_id: request.id
               })
             )

    assert {:ok, status} = Jido.AgentServer.status(server)
    assert status.raw_state.request_effects.status == :completed
    assert status.raw_state.request_effects.values[AttachDocuments] == []
  end

  test "provider failure after selection clears files and does not contaminate the next request" do
    a = record("failure-a") |> Record.metadata()

    {server, configured} =
      runtime([{:tool, "add", [a]}, {:http_error, 400}, {:text, "Recovered."}])

    {request, events} = ask(server, configured, "Select then fail")

    assert {:error, _, %{attachments: []}} =
             StreamEvents.consume(events, incoming(), request: request, runtime_pid: server)

    assert {:ok, status} = Jido.AgentServer.status(server)
    assert status.raw_state.request_effects.status == :failed
    assert status.raw_state.request_effects.values[AttachDocuments] == []
    {request, events} = ask(server, configured, "Fresh after failure")

    assert {:ok, %{attachments: [], answer: "Recovered."}} =
             StreamEvents.consume(events, incoming(), request: request, runtime_pid: server)
  end

  defp runtime(script, tools \\ ["data_source.attach_document"]) do
    {child, endpoint} = AttachmentSelectionLLMStub.server(script, self())
    start_supervised!(child)
    scope = "selection-#{Ecto.UUID.generate()}"

    configured =
      IntegrationAgent.create!(endpoint, scope, "Select files as instructed.", tools)

    {:ok, server} =
      ServerManager.ensure_server(configured, "#{configured.name}:#{scope}", nil,
        actor: %{kind: :system, subject: "selection-test"}
      )

    {GenServer.whereis(server), configured}
  end

  defp ask(server, configured, query) do
    assert {:ok, %{request: request, events: events}} =
             Factory.ask_with_config(server, query, configured,
               tool_context: %{skip_permissions: true}
             )

    {request, events}
  end

  defp incoming,
    do: %Incoming{content: "Select documents", channel_id: "selection", provider: :web}

  defp record(id) do
    {:ok, record} =
      Provenance.seal(%Record{
        id: id,
        kind: :file,
        parent_id: "root",
        name: id,
        content: "content #{id}",
        permissions: []
      })

    record
  end
end

defmodule Zaq.Agent.AttachmentSelectionDeliveryTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.People
  alias Zaq.Agent.{Answering, Executor, Pipeline, ServerManager}
  alias Zaq.Agent.Tools.DataSource.GetDocument
  alias Zaq.Channels.{DeliveryFiles, EmailBridge, JidoChatBridge}
  alias Zaq.Contracts.Record
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.Permissions
  alias Zaq.Storage.StorageEntry
  alias Zaq.Storage.VolumeConfig
  alias Zaq.SystemConfigFixtures

  alias Zaq.TestSupport.{
    AttachmentSelectionLLMStub,
    IntegrationAgent,
    MattermostHistoryFixture,
    OpenAIStub
  }

  test "configured Executor returns only B and Channels materializes it once for email delivery" do
    {a, b} = documents()

    script = [
      {:tool, "add", [model_record(a)]},
      {:tool, "add", [model_record(b)]},
      {:tool, "remove", [model_record(a)]},
      {:text, "Here is the requested file."}
    ]

    {child, endpoint} = AttachmentSelectionLLMStub.server(script, self())
    start_supervised!(child)
    scope = "delivery-#{Ecto.UUID.generate()}"

    configured =
      IntegrationAgent.create!(endpoint, scope, "Select the requested files.", [
        "data_source.attach_document"
      ])

    incoming = incoming()

    outgoing =
      Executor.run(incoming,
        agent_id: configured.id,
        scope: scope,
        skip_permissions: true,
        event: execution_event()
      )

    refute outgoing.metadata.error
    assert outgoing.body == "Here is the requested file."
    assert [%Record{id: id, content: nil, materialization_handle: handle}] = outgoing.attachments
    assert id == b.id
    assert is_binary(handle)
    refute Map.has_key?(outgoing.metadata, :attachments)
    refute_received {:email, _}

    # Authoritative Storage permission checks still run at final redemption.
    assert {:error, _} =
             DeliveryFiles.with_prepared(outgoing.attachments, %{}, fn _ ->
               flunk("unauthorized consumer invoked")
             end)

    smtp = smtp_config()

    outgoing = %{
      outgoing
      | provider: :"email:smtp",
        channel_id: "recipient@example.test",
        routing_context: %{channel_config_id: smtp.id}
    }

    assert {:ok, _} =
             EmailBridge.send_reply(outgoing, %{trusted_context: %{skip_permissions: true}})

    assert_receive {:email, email}
    assert [%Swoosh.Attachment{} = attachment] = email.attachments
    assert attachment.filename == "B.txt"
    assert Swoosh.Attachment.get_content(attachment) == "B bytes"
    assert email.text_body =~ outgoing.body
    refute_receive {:email, _}
  end

  test "legacy default Pipeline does not expose configured attachment selection" do
    {a, b} = documents()

    script = [
      {:tool, "add", [model_record(a)]},
      {:tool, "add", [model_record(b)]},
      {:tool, "remove", [model_record(a)]},
      {:text, "Selected B."}
    ]

    {child, endpoint} = AttachmentSelectionLLMStub.server(script, self())
    start_supervised!(child)

    SystemConfigFixtures.seed_llm_config(%{
      endpoint: endpoint,
      provider: "openai",
      api_key: "test-key",
      model: "gpt-4.1-mini",
      max_context_window: 128_000
    })

    configured = Answering.answering_configured_agent()
    on_exit(fn -> ServerManager.stop_server(configured) end)
    scope = "default-selection-#{Ecto.UUID.generate()}"

    outgoing =
      Pipeline.run(incoming(), scope: scope, skip_permissions: true, event: execution_event())

    refute outgoing.metadata.error
    assert outgoing.body == "Selected B."
    assert outgoing.attachments == []
    assert_receive {:attachment_model_request, 0, request}
    refute Enum.any?(request["tools"], &(&1["name"] == "attach_documents"))

    refute_received {:email, _}
  end

  test "Mattermost uploads only final B with the answer in the selected channel and thread" do
    {a, b} = documents()

    script = [
      {:tool, "add", [model_record(a)]},
      {:tool, "add", [model_record(b)]},
      {:tool, "remove", [model_record(a)]},
      {:text, "Here is B."}
    ]

    {child, endpoint} = AttachmentSelectionLLMStub.server(script, self())
    start_supervised!(child)
    scope = "mattermost-selection-#{Ecto.UUID.generate()}"

    configured =
      IntegrationAgent.create!(endpoint, scope, "Select files.", ["data_source.attach_document"])

    outgoing =
      Executor.run(incoming(),
        agent_id: configured.id,
        scope: scope,
        skip_permissions: true,
        event: execution_event()
      )

    assert [%Record{id: id}] = outgoing.attachments
    assert id == b.id

    owner = self()

    {child, endpoint} =
      OpenAIStub.server(
        fn conn, body ->
          MattermostHistoryFixture.delivery_http(conn, body, owner, "selection")
        end,
        owner
      )

    start_supervised!(Supervisor.child_spec(child, id: make_ref()))

    outgoing = %{
      outgoing
      | provider: :mattermost,
        channel_id: "shared-room",
        thread_id: "root-bot"
    }

    refute_received {:delivery_upload, _, _}

    delivery =
      Task.async(fn ->
        JidoChatBridge.send_reply(outgoing, %{
          url: String.trim_trailing(endpoint, "/v1"),
          token: "fixture-token",
          trusted_context: %{skip_permissions: true}
        })
      end)

    assert_receive {:delivery_upload, "selection", file}, 5_000
    assert file.filename == "B.txt"
    assert file.mime_type == "text/plain"
    assert file.bytes == "B bytes"
    assert file.channel_id == "shared-room"
    assert_receive {:delivery_boundary, "selection", provider_pid, %{post: post}}, 5_000
    assert post["message"] == "Here is B."
    assert post["root_id"] == "root-bot"
    assert post["file_ids"] == ["file-selection"]
    send(provider_pid, :accept_delivery)
    assert {:ok, _} = Task.await(delivery, 5_000)
    refute_receive {:delivery_upload, _, _}
  end

  test "empty replacement and failure return text without files, and incoming files are never echoed" do
    {a, _b} = documents()

    for terminal <- [{:text, "Text only."}, {:http_error, 400}] do
      script = [{:tool, "add", [model_record(a)]}, {:tool, "replace", []}, terminal]
      {child, endpoint} = AttachmentSelectionLLMStub.server(script, self())
      start_supervised!(child)
      scope = "empty-#{Ecto.UUID.generate()}"

      configured =
        IntegrationAgent.create!(endpoint, scope, "Clear the selection.", [
          "data_source.attach_document"
        ])

      outgoing =
        Executor.run(%{incoming() | attachments: [a]},
          agent_id: configured.id,
          scope: scope,
          skip_permissions: true,
          event: execution_event()
        )

      assert outgoing.attachments == []
      if match?({:text, _}, terminal), do: assert(outgoing.body == "Text only.")
    end
  end

  test "a person can select a Disk document through Storage ACLs without a bypass" do
    {a, b} = documents()

    {:ok, person} =
      People.create_person(%{full_name: "Attachment reader", email: "reader@example.test"})

    assert {:ok, grant} = Permissions.grant(%StorageEntry{id: b.id}, %{person_id: person.id})

    script = [
      {:tool, "add", [model_record(b)]},
      {:tool, "replace", [model_record(b), model_record(a)]},
      {:text, "Selected your file."}
    ]

    {child, endpoint} = AttachmentSelectionLLMStub.server(script, self())
    start_supervised!(child)
    scope = "person-selection-#{Ecto.UUID.generate()}"

    configured =
      IntegrationAgent.create!(endpoint, scope, "Select the file.", [
        "data_source.attach_document"
      ])

    actor = %{person: %{id: person.id}}

    outgoing =
      Executor.run(incoming(),
        agent_id: configured.id,
        scope: scope,
        event: Event.new(%{}, :agent, actor: actor)
      )

    refute outgoing.metadata.error
    assert [%Record{id: id}] = outgoing.attachments
    assert id == b.id
    assert Enum.map(outgoing.metadata.tool_calls, & &1["outcome"]) == ["succeeded", "failed"]

    assert {:ok, [%{content: "B bytes"}]} =
             DeliveryFiles.with_prepared(outgoing.attachments, %{actor: actor}, &{:ok, &1})

    assert :ok = Permissions.revoke(%StorageEntry{id: b.id}, grant)

    assert {:error, _} =
             DeliveryFiles.with_prepared(outgoing.attachments, %{actor: actor}, fn _ ->
               flunk("revoked file delivered")
             end)
  end

  defp execution_event,
    do: Event.new(%{}, :agent, actor: %{kind: :system, subject: "attachment-delivery-test"})

  defp incoming,
    do: %Incoming{
      content: "Select A and B, then remove A",
      channel_id: "test-selection",
      provider: :web
    }

  defp documents do
    relative = "selection-#{Ecto.UUID.generate()}"
    root = Path.join(VolumeConfig.base_path(), relative)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: relative,
        provider: "disk",
        kind: "data_source",
        enabled: true,
        settings: %{"volumes" => [%{"name" => "selected", "path" => relative}]}
      })
      |> Repo.insert!()

    records =
      for name <- ["A", "B"] do
        File.write!(Path.join(root, "#{name}.txt"), "#{name} bytes")
        id = "selected/#{name}.txt"

        {:ok, %{record: record}} =
          Jido.Exec.run(
            GetDocument,
            %{provider: "disk", document_id: id, config_id: to_string(config.id)},
            %{skip_permissions: true}
          )

        record
      end

    List.to_tuple(records)
  end

  defp model_record(record) do
    record
    |> Record.metadata()
    |> Map.put("permissions", record.permissions)
    |> Map.put("parent_id", record.parent_id)
  end

  defp smtp_config do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "selection-smtp",
      provider: "email:smtp",
      url: "smtp.example.test",
      token: "fixture-token",
      kind: "retrieval",
      enabled: true,
      settings: %{
        "relay" => "",
        "from_email" => "sender@example.test",
        "from_name" => "Selection"
      }
    })
    |> Repo.insert!()
  end
end
