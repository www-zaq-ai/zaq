defmodule Zaq.Engine.Conversations.ExecutionHistoryTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Jido.AI.Context, as: AIContext
  alias Jido.AI.Reasoning.ReAct.Config
  alias Zaq.Accounts.People
  alias Zaq.Agent.Api, as: AgentApi
  alias Zaq.Agent.ContextWindow.RequestTransformer
  alias Zaq.Agent.HistorySync
  alias Zaq.Agent.StreamEvents
  alias Zaq.Agent.Tools.DataSource.DownloadDocument
  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Channels.Materializers.CommunicationMedia
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Api, as: EngineApi
  alias Zaq.Engine.{ChannelConfig, Conversations, HistoryIngress}

  alias Zaq.Engine.Conversations.{
    ExecutionHistory,
    ExecutionRecord,
    Message,
    Transcript,
    TranscriptHistory,
    TranscriptMessage
  }

  alias Zaq.Engine.History.Facts
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.Materialization.Handle
  alias Zaq.Permissions
  alias Zaq.Permissions.ChannelHistoryResource
  alias Zaq.QueryRecorder

  defmodule AttachmentBridge do
    def materialize_record(request, opts) do
      send(opts[:actor][:observer], {:attachment_fetch, request})
      {:ok, %Zaq.Contracts.Record{id: request["reference"], kind: :file, content: "file bytes"}}
    end
  end

  setup do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Execution history",
        provider: "mattermost",
        kind: "retrieval",
        enabled: true,
        url: "https://history.example.test",
        token: "test-token"
      })
      |> Repo.insert!()

    {:ok, alice} = People.create_person(%{full_name: "Alice"})
    {:ok, bob} = People.create_person(%{full_name: "Bob"})

    for {person, external} <- [{alice, "alice"}, {bob, "bob"}] do
      {:ok, _} =
        People.add_channel(%{
          person_id: person.id,
          platform: "mattermost",
          channel_identifier: external,
          channel_config_id: config.id
        })
    end

    %{config: config, alice: alice, bob: bob}
  end

  test "authorized admission and delta responses hydrate stored media without persisting handles",
       ctx do
    source =
      CommunicationMedia.source_metadata("mattermost", "stored-file", %{
        "channel_config_id" => ctx.config.id,
        "source_author_id" => "alice",
        "source_channel_id" => "room",
        "source_message_id" => "media",
        "size" => 4
      })

    media = %{
      incoming(ctx, ctx.alice, "media", nil, nil)
      | attachments: [
          %Record{
            id: "stored-file",
            kind: :file,
            size: 4,
            attributes: %{"materialization_source" => source}
          }
        ]
    }

    assert {:ok, captured} = HistoryIngress.capture(media)
    {binding, _} = admitted(ctx)
    {:ok, permission} = grant(ctx)
    principal = Map.put(actor(ctx.alice), :id, "alice")

    admission =
      Event.new(%{binding: binding, content: "Current input"}, :engine,
        actor: principal,
        opts: [confidential: true]
      )

    assert %{response: {:ok, initial}} = EngineApi.handle_event(admission, :admit_execution, %{})
    assert [%{attachments: [attachment]}] = initial.messages
    assert is_binary(attachment["materialization_handle"])
    assert attachment["id"] == "stored-file"
    assert {:ok, %{locator: locator}} = Handle.verify(attachment["materialization_handle"])

    assert locator["canonical_attachment"] == %{
             "version" => 1,
             "transcript_id" => initial.transcript_id,
             "message_id" => captured.message_id
           }

    assert [stored] = Repo.get!(Message, captured.message_id).attachments
    refute Map.has_key?(stored, "materialization_handle")

    request = Map.put(binding, :after_cursors, %{initial.transcript_id => 0})
    history = Event.new(request, :engine, actor: principal, opts: [confidential: true])
    assert %{response: {:ok, delta}} = EngineApi.handle_event(history, :execution_history, %{})
    assert [%{attachments: [fresh]}] = delta.messages
    assert is_binary(fresh["materialization_handle"])
    assert delta.cursors == initial.cursors
    assert Repo.get!(Message, captured.message_id).attachments == [stored]
    assert :ok = Permissions.revoke(resource(ctx), permission)

    assert %{response: {:error, :unauthorized}} =
             EngineApi.handle_event(history, :execution_history, %{})
  end

  test "canonical admission and queued receipts carry original input author and recorded time",
       ctx do
    {binding, _} = admitted(ctx)
    grant(ctx)

    assert {:ok, projection} =
             Conversations.admit_execution(binding, actor(ctx.alice), "Current input")

    stored = Repo.get!(Message, binding.user_message_id)
    assert projection.input.author.name == ctx.alice.full_name
    assert projection.input.timestamp == %{value: stored.inserted_at, source: :recorded}

    input = incoming(ctx, ctx.alice, "attributed-correction", nil, "Correction")
    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, child} = Conversations.admit_incoming(input)
    assert {:ok, _} = Conversations.admit_execution(child, actor(ctx.alice), input.content)

    assert {:ok, receipt} =
             Conversations.queue_execution_input(binding.user_message_id, child, actor(ctx.alice),
               content: input.content
             )

    child_message = Repo.get!(Message, child.user_message_id)
    assert receipt.input.id == child_message.id
    assert receipt.input.author.name == ctx.alice.full_name
    assert receipt.input.timestamp == %{value: child_message.inserted_at, source: :recorded}
    refute Map.has_key?(receipt.input, :metadata)
  end

  test "canonical attachment reads share author and timestamp presentation with history", ctx do
    grant(ctx)

    for {id, sent_at} <- [
          {"provider-time", ~U[2026-01-02 03:04:05.123456Z]},
          {"recorded-time", nil}
        ] do
      source =
        CommunicationMedia.source_metadata("mattermost", id, %{
          "channel_config_id" => ctx.config.id,
          "source_author_id" => "bob",
          "source_channel_id" => "room",
          "source_message_id" => id
        })

      input = incoming(ctx, ctx.bob, id, nil, "Bob's attachment")

      input = %{
        input
        | routing_context: Map.put(input.routing_context, :provider_sent_at, sent_at),
          attachments: [
            %Record{id: id, kind: :file, attributes: %{"materialization_source" => source}}
          ]
      }

      assert {:ok, captured} = HistoryIngress.capture(input)

      placement =
        Repo.one!(from p in TranscriptMessage, where: p.message_id == ^captured.message_id)

      stored = Repo.get!(Message, captured.message_id)

      assert {:ok, listed} =
               Conversations.list_canonical_messages(ctx.alice, placement.transcript_id)

      listed = Enum.find(listed, &(&1.message_id == captured.message_id))

      event =
        Event.new(
          %{
            action: :canonical_message,
            transcript_id: placement.transcript_id,
            message_id: captured.message_id
          },
          :engine,
          actor: actor(ctx.alice),
          opts: [confidential: true]
        )

      assert %{response: {:ok, exact}} = EngineApi.handle_event(event, :conversation, %{})
      assert Map.delete(exact, :transcript_id) == listed
      assert exact.author.person_id == ctx.bob.id
      assert exact.author.name == ctx.bob.full_name

      expected_time =
        if sent_at,
          do: %{value: sent_at, source: :provider},
          else: %{value: stored.inserted_at, source: :recorded}

      assert exact.timestamp == expected_time
      refute Map.has_key?(exact, :metadata)
      refute Map.has_key?(exact, :history_context)
      assert [attachment] = exact.attachments
      refute Map.has_key?(attachment, "materialization_handle")
      assert attachment["attributes"]["materialization_source"] == source
    end
  end

  test "another transcript reader downloads a canonical attachment and revocation denies its old handle",
       ctx do
    source =
      CommunicationMedia.source_metadata("mattermost", "shared-file", %{
        "channel_config_id" => ctx.config.id,
        "source_author_id" => "bob",
        "source_channel_id" => "room",
        "source_message_id" => "shared-media"
      })

    media = %{
      incoming(ctx, ctx.bob, "shared-media", nil, "Bob's file")
      | attachments: [
          %Record{
            id: "shared-file",
            kind: :file,
            attributes: %{"materialization_source" => source}
          }
        ]
    }

    assert {:ok, captured} = HistoryIngress.capture(media)
    {binding, _} = admitted(ctx)

    {:ok, permission} =
      Permissions.grant(resource(ctx), %{
        person_id: ctx.alice.id,
        access_rights: ["read"],
        source_key: "channel_history:provider:mattermost"
      })

    event = Event.new(binding, :engine, actor: actor(ctx.alice), opts: [confidential: true])
    assert %{response: {:ok, projection}} = EngineApi.handle_event(event, :execution_history, %{})
    assert [%{attachments: [attachment]}] = projection.messages
    params = %{materialization_handle: attachment["materialization_handle"]}

    context = %{
      actor: Map.put(actor(ctx.alice), :observer, self()),
      communication_bridge_module: AttachmentBridge
    }

    assert {:ok, %{record: %Record{content: "file bytes"}}} =
             Jido.Exec.run(DownloadDocument, params, context)

    assert_received {:attachment_fetch, request}
    refute Map.has_key?(request, "canonical_attachment")
    assert request["source_author_id"] == "bob"

    assert {:error, _} =
             Jido.Exec.run(DownloadDocument, params, %{context | actor: actor(ctx.bob)})

    refute_received {:attachment_fetch, _}

    assert {:ok, manual} =
             Permissions.grant(resource(ctx), %{
               person_id: ctx.alice.id,
               access_rights: ["read"],
               source_key: "manual"
             })

    assert :ok = Permissions.revoke(resource(ctx), permission)
    assert {:ok, _} = Jido.Exec.run(DownloadDocument, params, context)
    assert_received {:attachment_fetch, _}
    assert :ok = Permissions.revoke(resource(ctx), manual)
    assert {:error, _} = Jido.Exec.run(DownloadDocument, params, context)
    refute_received {:attachment_fetch, _}

    assert {:ok, _} = grant(ctx)

    Repo.delete_all(
      from placement in TranscriptMessage, where: placement.message_id == ^captured.message_id
    )

    assert {:error, _} = Jido.Exec.run(DownloadDocument, params, context)
    refute_received {:attachment_fetch, _}
  end

  test "thread hydration signs the parent attachment placement rather than the active child",
       ctx do
    source =
      CommunicationMedia.source_metadata("mattermost", "root-file", %{
        "channel_config_id" => ctx.config.id,
        "source_author_id" => "bob",
        "source_channel_id" => "room",
        "source_message_id" => "root"
      })

    root = %{
      incoming(ctx, ctx.bob, "root", nil, "Root")
      | attachments: [
          %Record{id: "root-file", kind: :file, attributes: %{"materialization_source" => source}}
        ]
    }

    assert {:ok, captured} = HistoryIngress.capture(root)
    grant(ctx)
    {binding, _} = admitted(ctx, "root")
    event = Event.new(binding, :engine, actor: actor(ctx.alice), opts: [confidential: true])
    assert %{response: {:ok, projection}} = EngineApi.handle_event(event, :execution_history, %{})
    assert [%{attachments: [attachment]}] = projection.messages
    assert {:ok, %{locator: locator}} = Handle.verify(attachment["materialization_handle"])
    assert locator["canonical_attachment"]["transcript_id"] != projection.transcript_id
    assert locator["canonical_attachment"]["message_id"] == captured.message_id

    context = %{
      actor: Map.put(actor(ctx.alice), :observer, self()),
      communication_bridge_module: AttachmentBridge
    }

    assert {:ok, _} =
             Jido.Exec.run(
               DownloadDocument,
               %{materialization_handle: attachment["materialization_handle"]},
               context
             )

    assert_received {:attachment_fetch, _}
  end

  test "unavailable attachments remain readable and hydration transport failures are truthful",
       ctx do
    source =
      CommunicationMedia.source_metadata("mattermost", "file", %{
        "channel_config_id" => ctx.config.id,
        "source_author_id" => "bob",
        "source_channel_id" => "room",
        "source_message_id" => "unavailable-media"
      })

    media = %{
      incoming(ctx, ctx.bob, "unavailable-media", nil, "Stored attachment")
      | attachments: [
          %Record{
            id: "file",
            kind: :file,
            name: "bob.png",
            attributes: %{"materialization_source" => source}
          },
          %Record{id: "legacy", kind: :file, name: "legacy.png"}
        ]
    }

    assert {:ok, _} = HistoryIngress.capture(media)
    {binding, _} = admitted(ctx)
    grant(ctx)
    principal = Map.put(actor(ctx.alice), :id, "alice")
    event = Event.new(binding, :engine, actor: principal, opts: [confidential: true])
    assert %{response: {:ok, projection}} = EngineApi.handle_event(event, :execution_history, %{})
    assert [%{attachments: [other_author, legacy]}] = projection.messages
    assert is_binary(other_author["materialization_handle"])
    assert legacy["materialization_status"] == "unavailable"
    assert other_author["name"] == "bob.png"
    refute Map.has_key?(other_author, "materialization_status")
    refute Map.has_key?(legacy, "materialization_handle")

    expect(Zaq.NodeRouterMock, :dispatch, fn %Event{
                                               request: %{attachments: attachments},
                                               opts: opts
                                             } = request ->
      assert length(attachments) == 2
      assert opts[:action] == :hydrate_attachments
      assert opts[:confidential] == true
      %{request | response: {:error, :unavailable}}
    end)

    failed = %{event | opts: [confidential: true, node_router: Zaq.NodeRouterMock]}

    assert %{response: {:error, :attachment_hydration_unavailable}} =
             EngineApi.handle_event(failed, :execution_history, %{})
  end

  test "execution admission records authorization once without making history reads admissions",
       ctx do
    {binding, _} = admitted(ctx)
    grant(ctx)
    assert {:ok, _} = Conversations.execution_history(binding, actor(ctx.alice))
    assert is_nil(Repo.get!(ExecutionRecord, binding.execution_id).admitted_at)

    assert {:ok, projection} =
             Conversations.admit_execution(binding, actor(ctx.alice), "Current input")

    assert projection.kind == :canonical
    first = Repo.get!(ExecutionRecord, binding.execution_id)
    assert %DateTime{} = first.admitted_at

    assert {:ok, ^projection} =
             Conversations.admit_execution(binding, actor(ctx.alice), "Current input")

    assert Repo.get!(ExecutionRecord, binding.execution_id) == first
  end

  test "denial closes only a never-authorized provisional execution and preserves factual input",
       ctx do
    {binding, _} = admitted(ctx)
    message = Repo.get!(Message, binding.user_message_id)

    assert {:error, {:history_access_denied, denial}} =
             Conversations.admit_execution(binding, actor(ctx.alice), "Current input")

    assert denial.person_id == ctx.alice.id
    assert is_binary(denial.transcript_id)
    execution = Repo.get!(ExecutionRecord, binding.execution_id)
    assert execution.status == "failed"
    assert is_nil(execution.admitted_at)
    assert Repo.get!(Message, binding.user_message_id) == message
  end

  test "canonical model refresh rejects a missing request lease", ctx do
    {binding, _} = admitted(ctx)
    grant(ctx)

    assert {:ok, projection} =
             Conversations.admit_execution(binding, actor(ctx.alice), "Current input")

    assert {:error, :stale_history_lease} =
             RequestTransformer.transform_request(
               %{messages: []},
               %{context: AIContext.new()},
               struct(Config, llm: %{max_tokens: 10}),
               %{
                 actor: actor(ctx.alice),
                 node_router: Zaq.NodeRouter,
                 context_window: %{max_context_tokens: 1_000},
                 execution_history: %{
                   binding: binding,
                   cursors: projection.cursors,
                   scope: "missing-lease"
                 }
               }
             )
  end

  test "a denied replay cannot revoke an earlier accepted execution", ctx do
    {binding, _} = admitted(ctx)
    {:ok, permission} = grant(ctx)

    assert {:ok, _} =
             Conversations.admit_execution(binding, actor(ctx.alice), "Current input")

    accepted = Repo.get!(ExecutionRecord, binding.execution_id)
    assert :ok = Permissions.revoke(resource(ctx), permission)

    assert {:error, {:history_access_denied, _}} =
             Conversations.admit_execution(binding, actor(ctx.alice), "Current input")

    assert Repo.get!(ExecutionRecord, binding.execution_id) == accepted
    assert {:error, :unauthorized} = Conversations.execution_history(binding, actor(ctx.alice))
  end

  test "invalid admission cannot authorize or select another Person's runtime for retirement",
       ctx do
    {binding, _} = admitted(ctx)
    before = Repo.get!(ExecutionRecord, binding.execution_id)

    for {candidate, principal, content} <- [
          {binding, actor(ctx.bob), "Current input"},
          {%{binding | finalization_token: "forged"}, actor(ctx.alice), "Current input"},
          {binding, actor(ctx.alice), "Altered input"}
        ] do
      assert {:error, :unauthorized} =
               Conversations.admit_execution(candidate, principal, content)
    end

    assert Repo.get!(ExecutionRecord, binding.execution_id) == before
  end

  property "mutating any execution binding coordinate cannot authorize or read another scope",
           ctx do
    {binding, _} = admitted(ctx)
    grant(ctx)
    before = Repo.get!(ExecutionRecord, binding.execution_id)

    check all(
            field <-
              member_of([:conversation_id, :user_message_id, :execution_id, :finalization_token]),
            replacement <- member_of([nil, "", "invalid", Ecto.UUID.generate()]),
            max_runs: 24
          ) do
      candidate = Map.put(binding, field, replacement)

      # Omitting execution_id is a supported compatibility lookup when there is
      # exactly one input-bound execution; it is not a different coordinate.
      unless field == :execution_id and is_nil(replacement) do
        assert {:error, :unauthorized} =
                 Conversations.admit_execution(candidate, actor(ctx.alice), "Current input")

        assert {:error, :unauthorized} =
                 Conversations.execution_history(candidate, actor(ctx.alice))

        assert Repo.get!(ExecutionRecord, binding.execution_id) == before
      end
    end
  end

  test "conversation and execution ownership must both match the active principal", ctx do
    {binding, _} = admitted(ctx)
    grant(ctx)
    execution = Repo.get!(ExecutionRecord, binding.execution_id)
    assert {:ok, moved} = Conversations.update_execution_owner(execution, ctx.bob.id)

    for person <- [ctx.alice, ctx.bob] do
      assert {:error, :unauthorized} =
               Conversations.admit_execution(binding, actor(person), "Current input")

      assert {:error, :unauthorized} = Conversations.execution_history(binding, actor(person))

      assert {:error, :unauthorized} =
               Conversations.authorize_execution_control(binding.user_message_id, actor(person))
    end

    assert Repo.get!(ExecutionRecord, binding.execution_id) == moved
  end

  test "execution binding verification resolves its principal once before transcript policy",
       ctx do
    {binding, _} = admitted(ctx)
    grant(ctx)

    for operation <- [
          fn -> Conversations.admit_execution(binding, actor(ctx.alice), "Current input") end,
          fn -> Conversations.execution_history(binding, actor(ctx.alice)) end,
          fn ->
            Conversations.authorize_execution_control(binding.user_message_id, actor(ctx.alice))
          end
        ] do
      {result, queries} = QueryRecorder.capture(operation)
      assert result == :ok or match?({:ok, %{kind: :canonical}}, result)

      person_reads =
        Enum.filter(queries, fn query ->
          String.contains?(query.query, ~s(FROM "people")) and query.params == [ctx.alice.id]
        end)

      # One fresh owner resolution plus TranscriptHistory's independent Person
      # existence check. Execution ownership must reuse the resolved principal.
      assert length(person_reads) == 2
    end
  end

  test "an inactive principal cannot authorize execution or read with an earlier capability",
       ctx do
    {binding, _} = admitted(ctx)
    grant(ctx)
    assert {:ok, _} = Conversations.admit_execution(binding, actor(ctx.alice), "Current input")
    accepted = Repo.get!(ExecutionRecord, binding.execution_id)
    assert {:ok, _} = People.update_person(ctx.alice, %{status: "inactive"})

    assert {:error, :unauthorized} =
             Conversations.admit_execution(binding, actor(ctx.alice), "Current input")

    assert {:error, :unauthorized} = Conversations.execution_history(binding, actor(ctx.alice))
    assert Repo.get!(ExecutionRecord, binding.execution_id) == accepted
  end

  test "projects attributed root and local history once without current input or siblings", ctx do
    root = incoming(ctx, ctx.bob, "root", nil, "Project root")
    assert {:ok, _} = HistoryIngress.capture(root)
    grant(ctx)

    assert {:ok, _} =
             HistoryIngress.capture(incoming(ctx, ctx.bob, "local", "root", "Local note"))

    assert {:ok, _} =
             HistoryIngress.capture(incoming(ctx, ctx.bob, "sibling", "other-root", "FORBIDDEN"))

    question = incoming(ctx, ctx.alice, "question", "root", "Current input")
    assert {:ok, _} = HistoryIngress.capture(question)
    assert {:ok, binding} = Conversations.admit_incoming(question)
    assert {:ok, projection} = Conversations.execution_history(binding, actor(ctx.alice))
    assert projection.kind == :canonical
    assert Enum.map(projection.messages, & &1.content) == ["Project root", "Local note"]
    assert Enum.all?(projection.messages, &(&1.author_name == "Bob"))
    assert map_size(projection.cursors) == 2
    assert Enum.all?(projection.messages, &(not Map.has_key?(&1, :metadata)))
  end

  test "Engine admission requires a confidential event and ordinary changesets cannot forge evidence",
       ctx do
    {binding, _} = admitted(ctx)
    grant(ctx)
    execution = Repo.get!(ExecutionRecord, binding.execution_id)

    assert ExecutionRecord.changeset(execution, %{admitted_at: DateTime.utc_now()}).changes == %{}

    request = %{binding: binding, content: "Current input"}
    event = Event.new(request, :engine, actor: actor(ctx.alice))

    assert %{response: {:error, :confidential_event_required}} =
             Zaq.Engine.Api.handle_event(event, :admit_execution, nil)

    assert is_nil(Repo.get!(ExecutionRecord, binding.execution_id).admitted_at)
    event = %{event | opts: [confidential: true]}

    assert %{response: {:ok, %{kind: :canonical}}} =
             Zaq.Engine.Api.handle_event(event, :admit_execution, nil)
  end

  test "a terminal provisional root is not reopened by later permission", ctx do
    {binding, _} = admitted(ctx)

    assert {:error, {:history_access_denied, _}} =
             Conversations.admit_execution(binding, actor(ctx.alice), "Current input")

    grant(ctx)

    assert {:error, :terminal_request} =
             Conversations.admit_execution(binding, actor(ctx.alice), "Current input")

    assert is_nil(Repo.get!(ExecutionRecord, binding.execution_id).admitted_at)
  end

  test "only the live admission session can carry its accepted projection past grant loss", ctx do
    {binding, _} = admitted(ctx)
    {:ok, permission} = grant(ctx)

    HistorySync.with_session(fn session ->
      opts = [history_session: session]

      assert {:ok, initial} =
               HistorySync.execution_admission(
                 opts,
                 binding,
                 actor(ctx.alice),
                 "Current input"
               )

      assert :ok = Permissions.revoke(resource(ctx), permission)

      assert {:ok, ^initial} =
               HistorySync.execution_admission(
                 opts,
                 binding,
                 actor(ctx.alice),
                 "Current input"
               )

      assert {:error, :unauthorized} =
               HistorySync.execution_admission(
                 opts,
                 binding,
                 actor(ctx.bob),
                 "Current input"
               )

      assert {:error, :unauthorized} =
               HistorySync.execution_admission(
                 opts,
                 binding,
                 actor(ctx.alice),
                 "Changed after authorization"
               )

      assert {:error, {:history_access_denied, _}} =
               HistorySync.execution_admission(
                 [history_session: make_ref()],
                 binding,
                 actor(ctx.alice),
                 "Current input"
               )
    end)

    assert {:error, {:history_access_denied, _}} =
             HistorySync.execution_admission(
               [history_session: make_ref()],
               binding,
               actor(ctx.alice),
               "Current input"
             )
  end

  test "validates owner, literal active Person and admission capability before projection", ctx do
    {binding, _} = admitted(ctx)
    assert {:error, :unauthorized} = Conversations.execution_history(binding, nil)
    assert {:error, :unauthorized} = Conversations.execution_history(binding, actor(ctx.bob))

    assert {:error, :unauthorized} =
             Conversations.execution_history(binding, %{person: %{id: 9_999_999}})

    assert {:error, :unauthorized} =
             Conversations.execution_history(
               %{binding | finalization_token: "forged"},
               actor(ctx.alice)
             )

    assert {:ok, _} = People.update_person(ctx.alice, %{status: "inactive"})
    assert {:error, :unauthorized} = Conversations.execution_history(binding, actor(ctx.alice))
  end

  test "admitted legacy inputs retain connector routing without querying a nil canonical source",
       ctx do
    incoming =
      Incoming.new(%{
        content: "Legacy connector input",
        provider: :mattermost,
        channel_id: "legacy-room",
        message_id: "legacy-input",
        person: ctx.alice,
        author_id: "alice",
        routing_context: %{channel_config_id: ctx.config.id}
      })
      |> CommunicationBridge.put_conversation_identity()

    assert {:ok, binding} = Conversations.admit_incoming(incoming)
    assert Repo.get!(Message, binding.user_message_id).source_provider == nil

    assert Conversations.get_conversation!(binding.conversation_id).channel_config_id ==
             ctx.config.id

    HistorySync.with_session(fn session ->
      assert {:ok, %{kind: :legacy}} =
               HistorySync.execution_admission(
                 [history_session: session],
                 binding,
                 actor(ctx.alice),
                 incoming.content
               )
    end)

    assert {:ok, %{kind: :legacy}} = Conversations.execution_history(binding, actor(ctx.alice))
    assert {:error, :unauthorized} = Conversations.execution_history(binding, actor(ctx.bob))

    assert {:error, :unauthorized} =
             Conversations.execution_history(
               %{binding | finalization_token: "forged"},
               actor(ctx.alice)
             )

    assert {:error, :unauthorized} =
             Conversations.execution_history(binding, actor(ctx.alice), after_cursors: %{})
  end

  test "admission composer fallback contracts reject missing Person", ctx do
    {binding, _capture} = admitted(ctx)
    input = Repo.get!(Message, binding.user_message_id)
    conversation = Conversations.get_conversation!(binding.conversation_id)

    assert {:error, :unauthorized} = ExecutionHistory.scope(input, conversation, nil)
    assert {:error, :unauthorized} = ExecutionHistory.project_admission(input, conversation, nil)

    assert {:error, :unauthorized} =
             ExecutionHistory.delta_admission(input, conversation, nil, %{})
  end

  test "a legacy root cannot queue a canonical child without a canonical root placement", ctx do
    legacy =
      Incoming.new(%{
        content: "Legacy root",
        provider: :mattermost,
        channel_id: "legacy-room",
        message_id: "legacy-queue-root",
        person: ctx.alice,
        author_id: "alice",
        routing_context: %{channel_config_id: ctx.config.id}
      })
      |> CommunicationBridge.put_conversation_identity()

    assert {:ok, root} = Conversations.admit_incoming(legacy)
    assert Repo.get!(Message, root.user_message_id).source_provider == nil

    grant(ctx)
    child_input = incoming(ctx, ctx.alice, "canonical-queue-child", nil, "Correction")
    assert {:ok, _} = HistoryIngress.capture(child_input)
    assert {:ok, child} = Conversations.admit_incoming(child_input)
    assert {:ok, _} = Conversations.admit_execution(child, actor(ctx.alice), child_input.content)

    assert {:error, :unauthorized} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.alice))
  end

  test "canonical composer denies an input with no placement", ctx do
    {binding, _} = admitted(ctx)
    input = Repo.get!(Message, binding.user_message_id)
    conversation = Conversations.get_conversation!(binding.conversation_id)
    placement = Repo.get_by!(TranscriptMessage, message_id: input.id)
    Repo.delete!(placement)

    assert {:error, :unauthorized} = ExecutionHistory.scope(input, conversation, ctx.alice)

    assert {:error, :unauthorized} =
             ExecutionHistory.project_admission(input, conversation, ctx.alice)

    assert {:error, :unauthorized} =
             ExecutionHistory.delta_admission(input, conversation, ctx.alice, %{})
  end

  test "canonical composer denies a placement owned by another Person", ctx do
    {binding, _} = admitted(ctx)
    input = Repo.get!(Message, binding.user_message_id)
    conversation = Conversations.get_conversation!(binding.conversation_id)
    placement = Repo.get_by!(TranscriptMessage, message_id: input.id)
    transcript = Repo.get!(Transcript, placement.transcript_id)
    Repo.delete!(placement)

    private =
      %Transcript{}
      |> Transcript.changeset(%{
        strategy: "replicated",
        provider: transcript.provider,
        channel_config_id: transcript.channel_config_id,
        scope_key: "bob-private-#{input.id}",
        external_channel_id: transcript.external_channel_id,
        permission_resource_type: "person_history",
        permission_resource_id: "bob-private-#{input.id}",
        owner_person_id: ctx.bob.id
      })
      |> Repo.insert!()

    private = private |> Ecto.Changeset.change(next_position: 1) |> Repo.update!()

    %TranscriptMessage{}
    |> TranscriptMessage.changeset(%{
      transcript_id: private.id,
      message_id: input.id,
      position: 1,
      provenance: "captured"
    })
    |> Repo.insert!()

    assert {:error, :unauthorized} = ExecutionHistory.scope(input, conversation, ctx.alice)

    assert {:error, :unauthorized} =
             ExecutionHistory.project_admission(input, conversation, ctx.alice)

    assert {:error, :unauthorized} =
             ExecutionHistory.delta_admission(input, conversation, ctx.alice, %{})
  end

  test "canonical composer denies ambiguous placements without choosing a replica", ctx do
    {binding, _} = admitted(ctx)
    input = Repo.get!(Message, binding.user_message_id)
    conversation = Conversations.get_conversation!(binding.conversation_id)
    placement = Repo.get_by!(TranscriptMessage, message_id: input.id)
    transcript = Repo.get!(Transcript, placement.transcript_id)

    other =
      %Transcript{}
      |> Transcript.changeset(%{
        strategy: transcript.strategy,
        provider: transcript.provider,
        channel_config_id: transcript.channel_config_id,
        scope_key: "duplicate-placement-#{input.id}",
        external_channel_id: transcript.external_channel_id,
        permission_resource_type: transcript.permission_resource_type,
        permission_resource_id: transcript.permission_resource_id
      })
      |> Repo.insert!()

    other = other |> Ecto.Changeset.change(next_position: 1) |> Repo.update!()

    %TranscriptMessage{}
    |> TranscriptMessage.changeset(%{
      transcript_id: other.id,
      message_id: input.id,
      position: 1,
      provenance: "captured"
    })
    |> Repo.insert!()

    assert {:error, :unauthorized} = ExecutionHistory.scope(input, conversation, ctx.alice)

    assert {:error, :unauthorized} =
             ExecutionHistory.project_admission(input, conversation, ctx.alice)

    assert {:error, :unauthorized} =
             ExecutionHistory.delta_admission(input, conversation, ctx.alice, %{})
  end

  test "fixed association cursors return cumulative A then A+B without current input", ctx do
    grant(ctx)
    {binding, _} = admitted(ctx)
    assert {:ok, initial} = Conversations.execution_history(binding, actor(ctx.alice))
    opts = [after_cursors: initial.cursors]
    assert {:ok, _} = HistoryIngress.capture(incoming(ctx, ctx.bob, "delta-a", nil, "A"))

    {{:ok, first}, first_queries} =
      QueryRecorder.capture(fn ->
        Conversations.execution_history(binding, actor(ctx.alice), opts)
      end)

    assert Enum.map(first.messages, & &1.content) == ["A"]
    assert {:ok, _} = HistoryIngress.capture(incoming(ctx, ctx.bob, "delta-b", nil, "B"))

    {{:ok, second}, second_queries} =
      QueryRecorder.capture(fn ->
        Conversations.execution_history(binding, actor(ctx.alice), opts)
      end)

    assert Enum.map(second.messages, & &1.content) == ["A", "B"]
    assert first.cursors[initial.transcript_id] < second.cursors[initial.transcript_id]
    assert second.cursors == second.upper_cursors
    assert length(first_queries) == length(second_queries)

    for queries <- [first_queries, second_queries] do
      assert Enum.count(queries, &(&1[:source] == "transcript_messages")) == 1
    end

    assert {:ok, empty} =
             Conversations.execution_history(binding, actor(ctx.alice),
               after_cursors: second.cursors
             )

    assert empty.messages == []
  end

  test "delta pages never advance past omitted associations", ctx do
    grant(ctx)
    {binding, _} = admitted(ctx)
    assert {:ok, initial} = Conversations.execution_history(binding, actor(ctx.alice))

    for index <- 1..103 do
      assert {:ok, _} =
               HistoryIngress.capture(
                 incoming(ctx, ctx.bob, "page-#{index}", nil, "Note #{index}")
               )
    end

    assert {:ok, first} =
             Conversations.execution_history(binding, actor(ctx.alice),
               after_cursors: initial.cursors
             )

    assert length(first.messages) == 100
    assert first.cursors[initial.transcript_id] < first.upper_cursors[initial.transcript_id]

    assert {:ok, second} =
             Conversations.execution_history(binding, actor(ctx.alice),
               after_cursors: first.cursors
             )

    assert Enum.map(second.messages, & &1.content) == ["Note 101", "Note 102", "Note 103"]
    assert second.cursors == second.upper_cursors
  end

  test "delta cursors are source-specific and every refresh rechecks grants", ctx do
    assert {:ok, _} = HistoryIngress.capture(incoming(ctx, ctx.bob, "root", nil, "Root"))
    {:ok, permission} = grant(ctx)
    {binding, _} = admitted(ctx, "root")
    assert {:ok, initial} = Conversations.execution_history(binding, actor(ctx.alice))

    assert {:ok, _} =
             HistoryIngress.capture(incoming(ctx, ctx.bob, "parent-delta", nil, "Parent"))

    assert {:ok, _} =
             HistoryIngress.capture(incoming(ctx, ctx.bob, "thread-delta", "root", "Local"))

    assert {:ok, delta} =
             Conversations.execution_history(binding, actor(ctx.alice),
               after_cursors: initial.cursors
             )

    assert Enum.map(delta.messages, & &1.content) == ["Parent", "Local"]

    for cursors <- [
          %{},
          %{Ecto.UUID.generate() => 0},
          Map.put(initial.cursors, initial.transcript_id, -1),
          Map.put(initial.cursors, initial.transcript_id, 1_000_000)
        ] do
      assert {:error, :invalid_history_cursor} =
               Conversations.execution_history(binding, actor(ctx.alice), after_cursors: cursors)
    end

    for cursor <- [nil, []] do
      assert {:error, :invalid_history_cursor} =
               Conversations.execution_history(binding, actor(ctx.alice), after_cursors: cursor)
    end

    assert :ok = Permissions.revoke(resource(ctx), permission)

    assert {:error, :unauthorized} =
             Conversations.execution_history(binding, actor(ctx.alice),
               after_cursors: initial.cursors
             )
  end

  property "association suffixes preserve order, identity and cursor bounds", ctx do
    grant(ctx)
    {binding, _} = admitted(ctx)

    check all(count <- integer(0..12), skip <- integer(0..count), max_runs: 8) do
      assert {:ok, initial} = Conversations.execution_history(binding, actor(ctx.alice))

      messages =
        for index <- Enum.take(1..12, count) do
          id = Ecto.UUID.generate()

          assert {:ok, capture} =
                   HistoryIngress.capture(incoming(ctx, ctx.bob, id, nil, "Note #{index}"))

          capture.message_id
        end

      cursors = Map.update!(initial.cursors, initial.transcript_id, &(&1 + skip))

      assert {:ok, delta} =
               Conversations.execution_history(binding, actor(ctx.alice), after_cursors: cursors)

      assert Enum.map(delta.messages, & &1.message_id) == Enum.drop(messages, skip)
      assert delta.cursors == delta.upper_cursors

      assert delta.cursors[initial.transcript_id] ==
               initial.cursors[initial.transcript_id] + count

      assert {:ok, ^delta} =
               Conversations.execution_history(binding, actor(ctx.alice), after_cursors: cursors)
    end
  end

  test "Engine confidential dispatch forwards delta cursors without bypassing capability checks",
       ctx do
    grant(ctx)
    {binding, _} = admitted(ctx)
    assert {:ok, initial} = Conversations.execution_history(binding, actor(ctx.alice))
    assert {:ok, _} = HistoryIngress.capture(incoming(ctx, ctx.bob, "api-delta", nil, "Fresh"))
    request = Map.put(binding, :after_cursors, initial.cursors)
    event = Event.new(request, :engine, actor: actor(ctx.alice), opts: [confidential: true])
    assert %{response: {:ok, delta}} = Zaq.Engine.Api.handle_event(event, :execution_history, nil)
    assert Enum.map(delta.messages, & &1.content) == ["Fresh"]

    assert %{response: {:error, :confidential_event_required}} =
             Zaq.Engine.Api.handle_event(%{event | opts: []}, :execution_history, nil)

    assert %{response: {:error, :unauthorized}} =
             Zaq.Engine.Api.handle_event(
               %{event | actor: actor(ctx.bob)},
               :execution_history,
               nil
             )

    assert %{response: {:error, :unauthorized}} =
             Zaq.Engine.Api.handle_event(
               %{event | request: %{request | finalization_token: "forged"}},
               :execution_history,
               nil
             )
  end

  test "revocation on a later read denies access rather than falling back to private history",
       ctx do
    assert {:ok, _} = HistoryIngress.capture(incoming(ctx, ctx.bob, "root", nil, "Root"))
    {:ok, permission} = grant(ctx)
    {binding, _} = admitted(ctx, "root")
    assert {:ok, _} = Conversations.execution_history(binding, actor(ctx.alice))
    assert :ok = Permissions.revoke(resource(ctx), permission)
    assert {:error, :unauthorized} = Conversations.execution_history(binding, actor(ctx.alice))
  end

  test "a missing root does not discard authorized thread replies", ctx do
    assert {:ok, _} =
             HistoryIngress.capture(incoming(ctx, ctx.bob, "local", "missing-root", "Retained"))

    grant(ctx)
    {binding, _} = admitted(ctx, "missing-root")
    assert {:ok, projection} = Conversations.execution_history(binding, actor(ctx.alice))
    assert Enum.map(projection.messages, & &1.content) == ["Retained"]
  end

  test "a transcript UUID cannot be substituted for the admitted input's conversation", ctx do
    {binding, _} = admitted(ctx)
    transcript = Repo.one!(from t in Transcript, where: is_nil(t.parent_id))
    forged = %{binding | conversation_id: transcript.id}
    assert {:error, :unauthorized} = Conversations.execution_history(forged, actor(ctx.alice))
  end

  test "Direct thread execution includes its parent root in the child context", ctx do
    root = incoming(ctx, ctx.alice, "direct-root", nil, "Direct note", :one_to_one)
    assert {:ok, _} = HistoryIngress.capture(root)
    input = incoming(ctx, ctx.alice, "direct-question", "direct-root", "Question", :one_to_one)
    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, binding} = Conversations.admit_incoming(input)
    assert {:ok, projection} = Conversations.execution_history(binding, actor(ctx.alice))
    assert Enum.map(projection.messages, & &1.content) == ["Direct note"]
  end

  test "Replicated execution reads only the sender's authorized recipient copy", ctx do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "Mail delivery",
      provider: "email:smtp",
      kind: "retrieval",
      enabled: true,
      url: "smtp://mail.test",
      token: "test-token"
    })
    |> Repo.insert!()

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Mail history",
        provider: "email:imap",
        kind: "retrieval",
        enabled: true,
        url: "imap://mail.test",
        token: "test-token",
        settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}}
      })
      |> Repo.insert!()

    for {person, address} <- [{ctx.alice, "alice@test.example"}, {ctx.bob, "bob@test.example"}] do
      assert {:ok, _} =
               People.add_channel(%{
                 person_id: person.id,
                 platform: "email",
                 channel_identifier: address,
                 channel_config_id: config.id
               })
    end

    make = fn id, content ->
      Incoming.new(%{
        content: content,
        channel_id: "mail-thread",
        author_id: "alice@test.example",
        author_name: "Alice",
        message_id: id,
        person: ctx.alice,
        provider: :"email:imap",
        routing_context: %{
          channel_config_id: config.id,
          conversation_type: :recipient_addressed,
          topic_id: "INBOX",
          source_scope: "INBOX",
          identity_platform: "email",
          audience: %{
            platform: "email",
            sender: "alice@test.example",
            recipients: ["bob@test.example"]
          }
        }
      })
      |> CommunicationBridge.put_conversation_identity()
    end

    assert {:ok, _} = HistoryIngress.capture(make.("mail-root", "Mail note"))
    input = make.("mail-question", "Question")
    assert {:ok, capture} = HistoryIngress.capture(input)
    assert {:ok, binding} = Conversations.admit_incoming(input)
    assert {:ok, projection} = Conversations.execution_history(binding, actor(ctx.alice))
    assert projection.transcript_id == capture.transcript_ids[ctx.alice.id]
    assert Enum.map(projection.messages, & &1.content) == ["Mail note"]
    assert {:error, :unauthorized} = Conversations.execution_history(binding, actor(ctx.bob))
  end

  test "the Agent role rejects a forged capability before broadcasting request status", ctx do
    {binding, _} = admitted(ctx)
    session = "denied-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Zaq.PubSub, "chat:#{session}")
    input = incoming(ctx, ctx.alice, "question", nil, "Current input")
    input = %{input | metadata: Map.put(input.metadata, :session_id, session)}

    event =
      Event.new(input, :agent,
        actor: actor(ctx.alice),
        opts: [action: :run_pipeline]
      )

    event = %{
      event
      | assigns: %{"conversation_binding" => %{binding | finalization_token: "forged"}}
    }

    assert %{response: {:error, :unauthorized}, next_hop: nil} =
             AgentApi.handle_event(event, :run_pipeline, nil)

    refute_received {:status_update, _, _, _}
  end

  test "canonical admission creates one private root and finalization preserves public UUIDs",
       ctx do
    {binding, _} = admitted(ctx)
    execution = Repo.get_by!(ExecutionRecord, user_message_id: binding.user_message_id)
    assert execution.person_id == ctx.alice.id
    assert execution.status == "pending"
    refute execution.finalization_token_hash == binding.finalization_token

    result = %{
      answer: "Public answer",
      model: "test-model",
      prompt_tokens: 7,
      completion_tokens: 3,
      total_tokens: 10,
      measurements: %{
        "latency_ms" => 23,
        "turn_count" => 2,
        "llm_call_count" => 2,
        "tool_call_count" => 1,
        "input_tokens" => 7,
        "output_tokens" => 3,
        "total_tokens" => 10
      },
      trace: [%{"type" => "tool_call", "name" => "arithmetic.add", "result" => "PRIVATE_RESULT"}]
    }

    assert {:ok, finalized} =
             Conversations.finalize_incoming(
               binding.user_message_id,
               binding.finalization_token,
               result,
               actor: actor(ctx.alice)
             )

    assert {:ok, ^finalized} =
             Conversations.finalize_incoming(
               binding.user_message_id,
               binding.finalization_token,
               result,
               actor: actor(ctx.alice)
             )

    execution = Repo.get!(ExecutionRecord, execution.id)
    assert execution.status == "completed"
    assert execution.public_answer_message_id == finalized.assistant_message_id
    assert execution.usage["prompt_tokens"] == 7
    assert execution.trace_entries == result.trace
    assert execution.tool_results == result.trace

    assert execution.outcome["measurements"] == %{
             "latency_ms" => 23,
             "turn_count" => 2,
             "llm_call_count" => 2,
             "tool_call_count" => 1
           }

    answer = Repo.get!(Message, finalized.assistant_message_id)
    input = Repo.get!(Message, binding.user_message_id)
    assert answer.trace == []
    assert input.trace == []
    refute inspect(answer.metadata) =~ "PRIVATE_RESULT"
    assert answer.prompt_tokens == nil
    refute Map.has_key?(answer.metadata, "measurements")
    refute Map.has_key?(input.metadata, "measurements")
    assert Repo.aggregate(ExecutionRecord, :count) == 1
  end

  test "foreign actor cannot finalize a private execution even with its capability", ctx do
    {binding, _} = admitted(ctx)

    assert {:error, :unauthorized} =
             Conversations.finalize_incoming(
               binding.user_message_id,
               binding.finalization_token,
               %{answer: "Denied"},
               actor: actor(ctx.bob)
             )

    assert Repo.get_by!(ExecutionRecord, user_message_id: binding.user_message_id).status ==
             "pending"

    assert Repo.aggregate(Message, :count) == 1
  end

  test "failed canonical execution retains private diagnostics without a public answer", ctx do
    {binding, _} = admitted(ctx)

    assert {:ok, %{assistant_message_id: nil}} =
             Conversations.finalize_incoming(
               binding.user_message_id,
               binding.finalization_token,
               %{
                 error: true,
                 error_type: :timeout,
                 trace: [%{"content" => "PRIVATE_FAILURE"}],
                 measurements: %{
                   latency_ms: 0,
                   turn_count: 0,
                   llm_call_count: 0,
                   tool_call_count: 0,
                   prompt_tokens: 0
                 }
               },
               actor: actor(ctx.alice)
             )

    execution = Repo.get_by!(ExecutionRecord, user_message_id: binding.user_message_id)
    assert execution.status == "failed"
    assert execution.outcome["error_type"] == "timeout"
    assert execution.trace_entries == [%{"content" => "PRIVATE_FAILURE"}]

    assert execution.outcome["measurements"] == %{
             "latency_ms" => 0,
             "turn_count" => 0,
             "llm_call_count" => 0,
             "tool_call_count" => 0
           }

    assert Repo.get!(Message, binding.user_message_id).trace == []
  end

  test "execution control revalidates the literal Person and current canonical grants", ctx do
    {binding, _} = admitted(ctx)
    {:ok, permission} = grant(ctx)

    assert :ok =
             Conversations.authorize_execution_control(binding.user_message_id, actor(ctx.alice))

    assert {:error, :unauthorized} =
             Conversations.authorize_execution_control(binding.user_message_id, actor(ctx.bob))

    assert :ok = Permissions.revoke(resource(ctx), permission)

    assert {:error, :unauthorized} =
             Conversations.authorize_execution_control(binding.user_message_id, actor(ctx.alice))
  end

  test "queued input is not consumption proof and root termination seals outstanding receipts",
       ctx do
    {root, _} = admitted(ctx)
    grant(ctx)
    child_input = incoming(ctx, ctx.alice, "steering", nil, "Use this correction")
    assert {:ok, _} = HistoryIngress.capture(child_input)
    assert {:ok, child} = Conversations.admit_incoming(child_input)
    assert {:ok, _} = Conversations.admit_execution(child, actor(ctx.alice), child_input.content)

    assert {:ok, receipt} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.alice))

    assert receipt.refs.message_id == child.user_message_id
    assert Repo.get!(ExecutionRecord, receipt.execution_id).status == "queued"

    assert {:ok, result} =
             Conversations.finalize_incoming(
               root.user_message_id,
               root.finalization_token,
               %{answer: "Root answer"},
               actor: actor(ctx.alice)
             )

    record = Repo.get!(ExecutionRecord, receipt.execution_id)
    assert record.status == "unconsumed"
    assert record.public_answer_message_id == nil

    assert record.root_execution_id ==
             Repo.get_by!(ExecutionRecord, user_message_id: root.user_message_id).id

    assert {:error, :terminal_request} =
             Conversations.consume_execution_input(
               root.user_message_id,
               child.user_message_id,
               actor(ctx.alice)
             )

    assert result.assistant_message_id != nil
    assert Repo.aggregate(Message, :count) == 3
  end

  test "consumption is idempotent, private and never transfers the public answer", ctx do
    {root, _} = admitted(ctx)
    grant(ctx)
    input = incoming(ctx, ctx.alice, "consumed", nil, "Correction")
    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, child} = Conversations.admit_incoming(input)
    assert {:ok, _} = Conversations.admit_execution(child, actor(ctx.alice), input.content)

    assert {:ok, receipt} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.alice))

    assert {:ok, _} =
             StreamEvents.consume(
               [
                 %{kind: :input_injected, data: %{refs: receipt.refs}}
               ],
               incoming(ctx, ctx.alice, "question", nil, "Current input"),
               actor: actor(ctx.alice),
               execution_user_message_id: root.user_message_id
             )

    assert :ok =
             Conversations.consume_execution_input(
               root.user_message_id,
               child.user_message_id,
               actor(ctx.alice)
             )

    assert {:ok, _} =
             Conversations.finalize_incoming(
               root.user_message_id,
               root.finalization_token,
               %{answer: "One answer"},
               actor: actor(ctx.alice)
             )

    assert Repo.get!(ExecutionRecord, receipt.execution_id).status == "consumed"
    assert Repo.get!(ExecutionRecord, receipt.execution_id).public_answer_message_id == nil

    assert {:error, :terminal_request} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.alice))
  end

  test "an input losing the root-finalization race has a durable unconsumed disposition", ctx do
    {root, _} = admitted(ctx)
    grant(ctx)

    assert {:ok, _} =
             Conversations.finalize_incoming(
               root.user_message_id,
               root.finalization_token,
               %{answer: "Already completed"},
               actor: actor(ctx.alice)
             )

    incoming = incoming(ctx, ctx.alice, "late-input", nil, "Late correction")
    assert {:ok, _} = HistoryIngress.capture(incoming)
    assert {:ok, child} = Conversations.admit_incoming(incoming)
    assert {:ok, _} = Conversations.admit_execution(child, actor(ctx.alice), incoming.content)

    assert {:error, :terminal_request} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.alice))

    record = Repo.get_by!(ExecutionRecord, user_message_id: child.user_message_id)
    assert record.status == "unconsumed"
    assert record.public_answer_message_id == nil
    assert record.outcome["reason"] == "terminal_request"

    assert {:error, :terminal_request} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.alice))

    assert Repo.get!(ExecutionRecord, record.id) == record
    assert Repo.aggregate(Message, :count) == 3
  end

  test "terminal-input disposition cannot be forged by a foreign actor or invalid capability",
       ctx do
    {root, _} = admitted(ctx)
    grant(ctx)

    assert {:ok, _} =
             Conversations.finalize_incoming(
               root.user_message_id,
               root.finalization_token,
               %{answer: "Completed"},
               actor: actor(ctx.alice)
             )

    input = incoming(ctx, ctx.alice, "forged-late", nil, "Late correction")
    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, child} = Conversations.admit_incoming(input)
    before = Repo.get_by!(ExecutionRecord, user_message_id: child.user_message_id)

    assert {:error, :unauthorized} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.bob))

    assert {:error, :unauthorized} =
             Conversations.queue_execution_input(
               root.user_message_id,
               %{child | finalization_token: "forged"},
               actor(ctx.alice)
             )

    assert Repo.get!(ExecutionRecord, before.id) == before
  end

  test "runtime rejection seals only the unconsumed receipt and never overwrites consumption",
       ctx do
    {root, _} = admitted(ctx)
    grant(ctx)
    input = incoming(ctx, ctx.alice, "rejected-control", nil, "Correction")
    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, child} = Conversations.admit_incoming(input)
    assert {:ok, _} = Conversations.admit_execution(child, actor(ctx.alice), input.content)

    assert {:ok, receipt} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.alice))

    request =
      Event.new(
        %{
          root_user_message_id: root.user_message_id,
          user_message_id: child.user_message_id,
          reason: :stale_runtime
        },
        :engine,
        actor: actor(ctx.bob),
        opts: [action: :reject_execution_input, confidential: true]
      )

    assert %{response: {:error, :unauthorized}} = Zaq.NodeRouter.dispatch(request)
    assert %{response: :ok} = Zaq.NodeRouter.dispatch(%{request | actor: actor(ctx.alice)})
    record = Repo.get!(ExecutionRecord, receipt.execution_id)
    assert record.status == "unconsumed"
    assert record.outcome["reason"] == "stale_runtime"
    assert record.public_answer_message_id == nil

    assert Repo.get_by!(ExecutionRecord, user_message_id: root.user_message_id).status ==
             "pending"

    assert %{response: :ok} = Zaq.NodeRouter.dispatch(%{request | actor: actor(ctx.alice)})
    assert Repo.get!(ExecutionRecord, receipt.execution_id) == record

    consumed_input = incoming(ctx, ctx.alice, "consumption-wins", nil, "Another correction")
    assert {:ok, _} = HistoryIngress.capture(consumed_input)
    assert {:ok, consumed} = Conversations.admit_incoming(consumed_input)

    assert {:ok, _} =
             Conversations.admit_execution(consumed, actor(ctx.alice), consumed_input.content)

    assert {:ok, other} =
             Conversations.queue_execution_input(root.user_message_id, consumed, actor(ctx.alice))

    assert :ok =
             Conversations.consume_execution_input(
               root.user_message_id,
               consumed.user_message_id,
               actor(ctx.alice)
             )

    request = %{
      request
      | actor: actor(ctx.alice),
        request: %{request.request | user_message_id: consumed.user_message_id}
    }

    assert %{response: {:error, :input_consumed}} = Zaq.NodeRouter.dispatch(request)
    assert Repo.get!(ExecutionRecord, other.execution_id).status == "consumed"
  end

  test "root failure seals queued inputs but retains consumed correction evidence", ctx do
    {root, _} = admitted(ctx)
    grant(ctx)

    receipts =
      for {id, consumed?} <- [{"consumed-before-failure", true}, {"queued-before-failure", false}] do
        input = incoming(ctx, ctx.alice, id, nil, "Correction #{id}")
        assert {:ok, _} = HistoryIngress.capture(input)
        assert {:ok, binding} = Conversations.admit_incoming(input)
        assert {:ok, _} = Conversations.admit_execution(binding, actor(ctx.alice), input.content)

        assert {:ok, receipt} =
                 Conversations.queue_execution_input(
                   root.user_message_id,
                   binding,
                   actor(ctx.alice)
                 )

        if consumed?,
          do:
            assert(
              :ok ==
                Conversations.consume_execution_input(
                  root.user_message_id,
                  binding.user_message_id,
                  actor(ctx.alice)
                )
            )

        {receipt.execution_id, consumed?}
      end

    assert {:ok, %{assistant_message_id: nil}} =
             Conversations.finalize_incoming(
               root.user_message_id,
               root.finalization_token,
               %{
                 error: true,
                 error_type: :tool_failure,
                 trace: [%{"response" => "PRIVATE_FAILED_TOOL"}]
               },
               actor: actor(ctx.alice)
             )

    execution = Repo.get_by!(ExecutionRecord, user_message_id: root.user_message_id)
    assert execution.status == "failed"
    assert execution.outcome["error_type"] == "tool_failure"

    for {id, consumed?} <- receipts do
      receipt = Repo.get!(ExecutionRecord, id)
      assert receipt.status == if(consumed?, do: "consumed", else: "unconsumed")
      assert receipt.public_answer_message_id == nil
      assert receipt.root_execution_id == execution.id
    end

    assert Repo.aggregate(Message, :count) == 3
    assert Repo.get!(Message, root.user_message_id).trace == []
  end

  test "a receipt cannot finalize a public answer or failed root on behalf of its root", ctx do
    {root, _} = admitted(ctx)
    grant(ctx)
    input = incoming(ctx, ctx.alice, "child-finalization", nil, "Correction")
    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, binding} = Conversations.admit_incoming(input)
    assert {:ok, _} = Conversations.admit_execution(binding, actor(ctx.alice), input.content)

    assert {:ok, receipt} =
             Conversations.queue_execution_input(root.user_message_id, binding, actor(ctx.alice))

    before = Repo.get!(ExecutionRecord, receipt.execution_id)

    for result <- [%{answer: "Illegitimate second answer"}, %{error: true, error_type: :timeout}] do
      assert {:error, :input_not_root} =
               Conversations.finalize_incoming(
                 binding.user_message_id,
                 binding.finalization_token,
                 result,
                 actor: actor(ctx.alice)
               )

      assert Repo.get!(ExecutionRecord, before.id) == before
      assert Repo.aggregate(Message, :count) == 2
    end

    assert Repo.get_by!(ExecutionRecord, user_message_id: root.user_message_id).status ==
             "pending"
  end

  test "an older canonical message attached later is a new association delta", ctx do
    grant(ctx)

    assert {:ok, facts} =
             Facts.new(%{
               provider: "mattermost",
               channel_config_id: ctx.config.id,
               channel_id: "room",
               kind: :channel,
               actor_person_id: ctx.bob.id
             })

    attrs = %{
      role: "external",
      content: "Earlier canonical content",
      author_id: "bob",
      author_name: "Bob",
      external_message_id: "prepared-old",
      provider_sent_at: ~U[2020-01-01 00:00:00Z],
      attachments: []
    }

    source = %{
      provider: "mattermost",
      channel_config_id: ctx.config.id,
      provenance: "provider_event"
    }

    assert {:ok, prepared} = TranscriptHistory.prepare_capture(facts, attrs, source)
    old = Repo.get!(Message, prepared.message_id)
    {binding, _} = admitted(ctx)
    assert {:ok, initial} = Conversations.execution_history(binding, actor(ctx.alice))
    assert initial.messages == []

    assert DateTime.compare(
             old.inserted_at,
             Repo.get!(Message, binding.user_message_id).inserted_at
           ) in [:lt, :eq]

    assert {:ok, attached} = TranscriptHistory.capture(facts, attrs, source)
    assert attached.message_id == old.id

    assert {:ok, delta} =
             Conversations.execution_history(binding, actor(ctx.alice),
               after_cursors: initial.cursors
             )

    assert [message] = delta.messages
    assert message.message_id == old.id
    assert message.provider_sent_at == ~U[2020-01-01 00:00:00.000000Z]
    assert message.position > initial.cursors[initial.transcript_id]
    assert Repo.get!(Message, old.id) == old
  end

  defp admitted(ctx, thread \\ nil) do
    input = incoming(ctx, ctx.alice, "question", thread, "Current input")
    assert {:ok, capture} = HistoryIngress.capture(input)
    assert {:ok, binding} = Conversations.admit_incoming(input)
    {binding, capture}
  end

  test "an accepted correction queues after access loss without reauthorizing its root", ctx do
    {root, _} = admitted(ctx)
    {:ok, permission} = grant(ctx)
    input = incoming(ctx, ctx.alice, "admitted-correction", nil, "Accepted correction")
    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, child} = Conversations.admit_incoming(input)
    assert {:ok, _} = Conversations.admit_execution(child, actor(ctx.alice), input.content)
    assert :ok = Permissions.revoke(resource(ctx), permission)

    assert {:ok, receipt} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.alice),
               content: input.content
             )

    assert Repo.get!(ExecutionRecord, receipt.execution_id).status == "queued"

    assert {:error, :unauthorized} =
             Conversations.authorize_execution_control(root.user_message_id, actor(ctx.alice))
  end

  test "requeueing an already pending receipt is rejected without changing it", ctx do
    {root, _} = admitted(ctx)
    grant(ctx)
    input = incoming(ctx, ctx.alice, "pending-requeue", nil, "Pending correction")
    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, child} = Conversations.admit_incoming(input)
    assert {:ok, _} = Conversations.admit_execution(child, actor(ctx.alice), input.content)

    assert {:ok, receipt} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.alice))

    before = Repo.get!(ExecutionRecord, receipt.execution_id)

    assert :ok =
             Conversations.consume_execution_input(
               root.user_message_id,
               child.user_message_id,
               actor(ctx.alice)
             )

    assert {:error, :input_consumed} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.alice))

    consumed = Repo.get!(ExecutionRecord, receipt.execution_id)
    assert consumed.status == "consumed"
    assert consumed.root_execution_id == before.root_execution_id
  end

  test "a pending receipt cannot be queued under another root", ctx do
    {root, _} = admitted(ctx)
    grant(ctx)
    second_input = incoming(ctx, ctx.alice, "second-root", nil, "Second root")
    assert {:ok, _} = HistoryIngress.capture(second_input)
    assert {:ok, second_root} = Conversations.admit_incoming(second_input)
    input = incoming(ctx, ctx.alice, "root-conflict", nil, "Correction")
    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, child} = Conversations.admit_incoming(input)
    assert {:ok, _} = Conversations.admit_execution(child, actor(ctx.alice), input.content)

    assert {:ok, receipt} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.alice))

    before = Repo.get!(ExecutionRecord, receipt.execution_id)

    assert {:error, :input_conflict} =
             Conversations.queue_execution_input(
               second_root.user_message_id,
               child,
               actor(ctx.alice)
             )

    assert Repo.get!(ExecutionRecord, receipt.execution_id) == before
    assert before.status == "queued"
    assert before.root_execution_id == root.execution_id
  end

  test "followup preparation rejects a still-queued receipt without creating another execution",
       ctx do
    {root, _} = admitted(ctx)
    grant(ctx)
    input = incoming(ctx, ctx.alice, "queued-followup", nil, "Queued correction")
    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, child} = Conversations.admit_incoming(input)
    assert {:ok, _} = Conversations.admit_execution(child, actor(ctx.alice), input.content)

    assert {:ok, receipt} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.alice))

    before = Repo.get!(ExecutionRecord, receipt.execution_id)

    request = %{
      root_user_message_id: root.user_message_id,
      root_execution_id: root.execution_id,
      receipt_execution_id: receipt.execution_id,
      binding: child,
      content: input.content,
      disposition: :closed_before_accept
    }

    assert {:error, :input_conflict} =
             Conversations.prepare_execution_followup(request, actor(ctx.alice))

    assert Repo.get!(ExecutionRecord, receipt.execution_id) == before
    assert Repo.aggregate(ExecutionRecord, :count) == 2
  end

  test "an admitted but unqueued child cannot consume an execution input", ctx do
    {root, _} = admitted(ctx)
    grant(ctx)
    input = incoming(ctx, ctx.alice, "unlinked-consume", nil, "Correction")
    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, child} = Conversations.admit_incoming(input)
    assert {:ok, _} = Conversations.admit_execution(child, actor(ctx.alice), input.content)
    before = Repo.get_by!(ExecutionRecord, user_message_id: child.user_message_id)

    assert {:error, :input_conflict} =
             Conversations.consume_execution_input(
               root.user_message_id,
               child.user_message_id,
               actor(ctx.alice)
             )

    assert Repo.get!(ExecutionRecord, before.id) == before

    assert Repo.get_by!(ExecutionRecord, user_message_id: root.user_message_id).status ==
             "pending"
  end

  test "a captured canonical input cannot authorize consumption against a different root", ctx do
    {root, _} = admitted(ctx)
    grant(ctx)
    canonical = incoming(ctx, ctx.alice, "canonical-unlinked", nil, "Canonical input")
    assert {:ok, canonical_capture} = HistoryIngress.capture(canonical)
    separate = incoming(ctx, ctx.alice, "separate-child", nil, "Separate child")
    assert {:ok, _} = HistoryIngress.capture(separate)
    assert {:ok, child} = Conversations.admit_incoming(separate)
    assert {:ok, _} = Conversations.admit_execution(child, actor(ctx.alice), separate.content)
    before = Repo.get_by!(ExecutionRecord, user_message_id: child.user_message_id)

    assert {:error, :unauthorized} =
             Conversations.consume_execution_input(
               root.user_message_id,
               canonical_capture.message_id,
               actor(ctx.alice)
             )

    assert Repo.get!(ExecutionRecord, before.id) == before
  end

  test "rejecting an unlinked pending child conflicts without changing either record", ctx do
    {root, _} = admitted(ctx)
    grant(ctx)

    inputs =
      for {id, content} <- [{"reject-first", "First"}, {"reject-second", "Second"}] do
        input = incoming(ctx, ctx.alice, id, nil, content)
        assert {:ok, _} = HistoryIngress.capture(input)
        assert {:ok, child} = Conversations.admit_incoming(input)
        assert {:ok, _} = Conversations.admit_execution(child, actor(ctx.alice), content)
        {child, content}
      end

    [{first, first_content}, {second, second_content}] = inputs
    first_before = Repo.get_by!(ExecutionRecord, user_message_id: first.user_message_id)
    second_before = Repo.get_by!(ExecutionRecord, user_message_id: second.user_message_id)
    assert first_content != second_content

    assert {:error, :input_conflict} =
             Conversations.reject_execution_input(
               root.user_message_id,
               second.user_message_id,
               actor(ctx.alice),
               :stale_runtime
             )

    assert Repo.get!(ExecutionRecord, first_before.id) == first_before
    assert Repo.get!(ExecutionRecord, second_before.id) == second_before
  end

  test "queueing cannot turn a captured provisional input or its capability into admission",
       ctx do
    {root, _} = admitted(ctx)
    grant(ctx)
    input = incoming(ctx, ctx.alice, "not-admitted", nil, "Not yet accepted")
    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, child} = Conversations.admit_incoming(input)
    before = Repo.get!(ExecutionRecord, child.execution_id)
    assert before.admitted_at == nil

    assert {:error, :admission_required} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.alice),
               content: input.content
             )

    assert Repo.get!(ExecutionRecord, child.execution_id) == before
    assert {:ok, _} = Conversations.admit_execution(child, actor(ctx.alice), input.content)

    assert {:ok, _} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.alice),
               content: input.content
             )
  end

  for revoked? <- [false, true] do
    @recovery_revoked revoked?
    test "closed input creates one execution-addressed followup without changing its receipt (revoked #{@recovery_revoked})",
         ctx do
      {root, _} = admitted(ctx)
      {:ok, permission} = grant(ctx)
      input = incoming(ctx, ctx.alice, "recoverable-input", nil, "Late correction")
      assert {:ok, _} = HistoryIngress.capture(input)
      assert {:ok, child} = Conversations.admit_incoming(input)
      assert {:ok, _} = Conversations.admit_execution(child, actor(ctx.alice), input.content)

      HistorySync.with_session(fn session ->
        opts = [history_session: session]

        assert {:ok, _} =
                 HistorySync.execution_admission(opts, child, actor(ctx.alice), input.content)

        assert {:ok, receipt} =
                 Conversations.queue_execution_input(
                   root.user_message_id,
                   child,
                   actor(ctx.alice)
                 )

        assert :ok =
                 Conversations.reject_execution_input(
                   root.user_message_id,
                   child.user_message_id,
                   actor(ctx.alice),
                   :closed_before_accept
                 )

        before = Repo.get!(ExecutionRecord, receipt.execution_id)
        message = Repo.get!(Message, child.user_message_id)

        request = %{
          root_user_message_id: root.user_message_id,
          root_execution_id: receipt.root_execution_id,
          receipt_execution_id: receipt.execution_id,
          binding: child,
          content: input.content,
          disposition: :closed_before_accept
        }

        assert {:error, :prior_execution_not_completed} =
                 Conversations.prepare_execution_followup(request, actor(ctx.alice))

        assert {:ok, _} =
                 Conversations.finalize_incoming(
                   root.user_message_id,
                   root.finalization_token,
                   %{answer: "Prior answer"},
                   actor: actor(ctx.alice)
                 )

        if @recovery_revoked, do: assert(:ok = Permissions.revoke(resource(ctx), permission))

        assert {:ok, recovered} =
                 Conversations.prepare_execution_followup(request, actor(ctx.alice))

        assert {:error, :unauthorized} =
                 Conversations.authorize_execution_control(
                   child.user_message_id,
                   actor(ctx.alice)
                 )

        assert {:error, :admission_required} =
                 HistorySync.inherit_admission(
                   opts,
                   child,
                   recovered,
                   actor(ctx.alice),
                   "Changed content"
                 )

        assert :ok =
                 HistorySync.inherit_admission(
                   opts,
                   child,
                   recovered,
                   actor(ctx.alice),
                   input.content
                 )

        assert {:ok, first} =
                 HistorySync.execution_admission(opts, recovered, actor(ctx.alice), input.content)

        assert {:ok, second} =
                 HistorySync.execution_admission(opts, recovered, actor(ctx.alice), input.content)

        assert first == second
        assert recovered.user_message_id == child.user_message_id
        refute recovered.execution_id == receipt.execution_id
        refute recovered.finalization_token == child.finalization_token
        assert Repo.get!(ExecutionRecord, receipt.execution_id) == before
        assert Repo.get!(Message, child.user_message_id) == message

        assert Repo.get!(ExecutionRecord, recovered.execution_id).admitted_at ==
                 before.admitted_at

        assert %DateTime{} = before.admitted_at

        if @recovery_revoked do
          assert {:error, :unauthorized} =
                   Conversations.execution_history(recovered, actor(ctx.alice))
        else
          assert {:ok, _} = Conversations.execution_history(recovered, actor(ctx.alice))
        end

        assert {:error, :unauthorized} =
                 Conversations.execution_history(
                   %{recovered | finalization_token: child.finalization_token},
                   actor(ctx.alice)
                 )

        assert {:error, :ambiguous_execution} =
                 Conversations.finalize_incoming(
                   child.user_message_id,
                   child.finalization_token,
                   %{answer: "Wrong"},
                   actor: actor(ctx.alice)
                 )

        assert {:ok, :already_prepared} =
                 Conversations.prepare_execution_followup(request, actor(ctx.alice))

        assert {:ok, answer} =
                 Conversations.finalize_incoming(
                   recovered.user_message_id,
                   recovered.finalization_token,
                   %{
                     answer: "Hola",
                     total_tokens: 7,
                     trace: [%{"type" => "tool_call", "response" => "private"}]
                   },
                   actor: actor(ctx.alice),
                   execution_id: recovered.execution_id
                 )

        assert {:ok, ^answer} =
                 Conversations.finalize_incoming(
                   recovered.user_message_id,
                   recovered.finalization_token,
                   %{answer: "Duplicate"},
                   actor: actor(ctx.alice),
                   execution_id: recovered.execution_id
                 )

        owner = Repo.get!(ExecutionRecord, recovered.execution_id)
        assert owner.recovered_from_execution_id == receipt.execution_id
        assert owner.root_execution_id == nil
        assert owner.status == "completed"
        assert owner.usage["total_tokens"] == 7
        assert owner.public_answer_message_id == answer.assistant_message_id
        assert Repo.get!(ExecutionRecord, receipt.execution_id) == before
        assert Repo.aggregate(Message, :count) == 4
      end)
    end
  end

  test "finalization before queue supplies a committed disposition only to live admission", ctx do
    {root, _} = admitted(ctx)
    grant(ctx)
    input = incoming(ctx, ctx.alice, "closed-before-queue", nil, "Late correction")
    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, child} = Conversations.admit_incoming(input)
    assert {:ok, _} = Conversations.admit_execution(child, actor(ctx.alice), input.content)

    assert {:ok, _} =
             Conversations.finalize_incoming(
               root.user_message_id,
               root.finalization_token,
               %{answer: "Prior answer"},
               actor: actor(ctx.alice),
               execution_id: root.execution_id
             )

    opts = [
      root_execution_id: root.execution_id,
      closed_disposition: true,
      content: input.content
    ]

    assert {:error, {:closed_before_accept, receipt}} =
             Conversations.queue_execution_input(
               root.user_message_id,
               child,
               actor(ctx.alice),
               opts
             )

    assert receipt.execution_id == child.execution_id
    assert receipt.root_execution_id == root.execution_id
    before = Repo.get!(ExecutionRecord, receipt.execution_id)
    assert before.status == "unconsumed"

    assert {:error, :terminal_request} =
             Conversations.queue_execution_input(
               root.user_message_id,
               child,
               actor(ctx.alice),
               Keyword.delete(opts, :closed_disposition)
             )

    assert Repo.get!(ExecutionRecord, receipt.execution_id) == before

    request = %{
      root_user_message_id: root.user_message_id,
      root_execution_id: root.execution_id,
      receipt_execution_id: receipt.execution_id,
      binding: child,
      content: input.content,
      disposition: :closed_before_accept
    }

    assert {:ok, recovered} = Conversations.prepare_execution_followup(request, actor(ctx.alice))
    assert recovered.user_message_id == child.user_message_id
    assert Repo.get!(ExecutionRecord, receipt.execution_id) == before
  end

  test "followup preparation rejects foreign principals, invalid admission and consumed evidence",
       ctx do
    {root, _} = admitted(ctx)
    grant(ctx)
    input = incoming(ctx, ctx.alice, "consumed-recovery", nil, "Correction")
    assert {:ok, _} = HistoryIngress.capture(input)
    assert {:ok, child} = Conversations.admit_incoming(input)
    assert {:ok, _} = Conversations.admit_execution(child, actor(ctx.alice), input.content)

    assert {:ok, receipt} =
             Conversations.queue_execution_input(root.user_message_id, child, actor(ctx.alice))

    assert :ok =
             Conversations.consume_execution_input(
               root.user_message_id,
               child.user_message_id,
               actor(ctx.alice)
             )

    assert {:ok, _} =
             Conversations.finalize_incoming(
               root.user_message_id,
               root.finalization_token,
               %{answer: "Done"},
               actor: actor(ctx.alice)
             )

    request = %{
      root_user_message_id: root.user_message_id,
      root_execution_id: receipt.root_execution_id,
      receipt_execution_id: receipt.execution_id,
      binding: child,
      content: input.content,
      disposition: :closed_before_accept
    }

    assert {:error, :input_consumed} =
             Conversations.prepare_execution_followup(request, actor(ctx.alice))

    assert {:error, :unauthorized} =
             Conversations.prepare_execution_followup(request, actor(ctx.bob))

    forged = %{request | binding: %{child | finalization_token: "forged"}}

    assert {:error, :unauthorized} =
             Conversations.prepare_execution_followup(forged, actor(ctx.alice))

    assert Repo.aggregate(ExecutionRecord, :count) == 2
  end

  test "recipient-owned canonical replies bind admission to each sender, not the email thread's first owner",
       ctx do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "Recipient delivery",
      provider: "email:smtp",
      kind: "retrieval",
      enabled: true,
      url: "localhost",
      token: "test-token",
      settings: %{"from_email" => "bot@example.com", "from_name" => "ZAQ"}
    })
    |> Repo.insert!()

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Recipient admission",
        provider: "email:imap",
        kind: "retrieval",
        enabled: true,
        url: "localhost",
        token: "test-token",
        settings: %{
          "imap" => %{"username" => "bot@example.com", "selected_mailboxes" => ["INBOX"]}
        }
      })
      |> Repo.insert!()

    for {person, email} <- [{ctx.alice, "alice@example.com"}, {ctx.bob, "bob@example.com"}] do
      assert {:ok, _} =
               People.add_channel(%{
                 person_id: person.id,
                 platform: "email",
                 channel_identifier: email,
                 channel_config_id: config.id
               })
    end

    bindings =
      Enum.map(
        [
          {ctx.alice, "alice@example.com", "alice-input"},
          {ctx.bob, "bob@example.com", "bob-input"}
        ],
        fn {person, email, id} ->
          incoming =
            Incoming.new(%{
              content: "#{person.full_name} question",
              provider: :"email:imap",
              channel_id: email,
              author_id: email,
              message_id: id,
              person: person,
              routing_context: %{
                channel_config_id: config.id,
                conversation_type: :recipient_addressed,
                conversation_id: "public-thread",
                source_scope: "INBOX",
                audience: %{
                  platform: "email",
                  sender: email,
                  recipients: ["alice@example.com", "bob@example.com"]
                }
              }
            })
            |> CommunicationBridge.put_conversation_identity()

          assert {:ok, capture} = HistoryIngress.capture(incoming)
          assert {:ok, binding} = Conversations.admit_incoming(incoming)
          conversation = Conversations.get_conversation!(binding.conversation_id)
          assert conversation.person_id == person.id
          assert conversation.channel_config_id == config.id
          assert conversation.external_channel_id == "public-thread"
          assert Repo.get!(Message, binding.user_message_id).id == capture.message_id

          assert {:ok, %{kind: :canonical, transcript_id: transcript_id}} =
                   Conversations.execution_history(binding, actor(person))

          assert %{strategy: "replicated", owner_person_id: owner_id} =
                   Repo.get!(Transcript, transcript_id)

          assert owner_id == person.id
          other = if person.id == ctx.alice.id, do: ctx.bob, else: ctx.alice
          assert {:error, :unauthorized} = Conversations.execution_history(binding, actor(other))
          assert {:ok, replay} = Conversations.admit_incoming(incoming)
          assert replay.admitted? == false
          assert replay.user_message_id == binding.user_message_id
          assert replay.conversation_id == binding.conversation_id
          binding
        end
      )

    [alice, bob] = bindings
    refute alice.conversation_id == bob.conversation_id
    assert Conversations.get_conversation!(alice.conversation_id).person_id == ctx.alice.id
  end

  defp incoming(ctx, person, id, thread, content, type \\ :room) do
    Incoming.new(%{
      content: content,
      channel_id: "room",
      author_id: String.downcase(person.full_name),
      author_name: person.full_name,
      message_id: id,
      provider: :mattermost,
      person: person,
      thread_id: thread,
      routing_context: %{
        channel_config_id: ctx.config.id,
        conversation_type: type,
        thread_id: thread
      }
    })
    |> CommunicationBridge.put_conversation_identity()
  end

  defp actor(person), do: %{person: %{id: person.id}}
  defp resource(ctx), do: ChannelHistoryResource.for("mattermost", ctx.config.id, "room")

  defp grant(ctx),
    do: Permissions.grant(resource(ctx), %{person_id: ctx.alice.id, access_rights: ["read"]})
end
