defmodule Zaq.Agent.Tools.Accounts.HistoryTest do
  use Zaq.DataCase, async: true

  @moduletag capture_log: true

  alias Jido.Action.Runtime
  alias Zaq.Accounts.People
  alias Zaq.Agent.Tools.Accounts.History
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.Conversation

  # Identity is resolved from the trusted execution context:
  # - chat path:     ctx[:person_id] (set by the pipeline from the channel author)
  # - workflow path: ctx[:actor][:person][:id] (set by StepRunner from source_event.actor)
  # - machine path:  ctx[:skip_permissions] == true honors params[:person_id]
  # The LLM-facing person_id param is ignored on non-machine paths.

  defp create_person(email) do
    {:ok, person} = People.create_person(%{full_name: "Test Person", email: email})
    person
  end

  defp create_conversation(person_id, attrs \\ %{}) do
    {:ok, conv} =
      Conversations.create_conversation(
        Map.merge(
          %{
            channel_type: "bo",
            channel_user_id: "u_#{System.unique_integer([:positive])}",
            person_id: person_id
          },
          attrs
        )
      )

    conv
  end

  defp add_messages(conv, count, content_prefix \\ "Message") do
    for i <- 1..count do
      {:ok, _} =
        Conversations.add_message(conv, %{role: "user", content: "#{content_prefix} #{i}"})
    end
  end

  defp add_message(conv, role, content) do
    {:ok, message} = Conversations.add_message(conv, %{role: role, content: content})
    message
  end

  defp set_updated_at(conv, datetime) do
    {1, _} =
      Repo.update_all(
        from(c in Conversation, where: c.id == ^conv.id),
        set: [updated_at: datetime]
      )

    :ok
  end

  defp conversation_ids(result), do: Enum.map(result.conversations, & &1.id)

  # ── schema validity (chat-path output validation) ───────────────────

  describe "Jido schemas" do
    test "params and output schemas are valid NimbleOptions schemas" do
      # The chat tool-exec path (Jido.Action.Exec) builds NimbleOptions from
      # these at call time — an invalid type only explodes in production, not
      # in direct History.run/2 unit tests. Pin validity here.
      assert %NimbleOptions{} = NimbleOptions.new!(History.schema())
      assert %NimbleOptions{} = NimbleOptions.new!(History.output_schema())
    end

    test "a real result passes the runtime output validator" do
      assert {:ok, _} =
               Runtime.validate_output(
                 %{
                   conversations: [],
                   metadata: %{
                     total: %{},
                     current_window: %{}
                   }
                 },
                 History
               )
    end
  end

  # ── identity resolution — chat path ─────────────────────────────────

  describe "run/2 — chat identity (ctx person_id)" do
    test "returns the context person's conversations" do
      person = create_person("chat_self@example.com")
      conv = create_conversation(person.id)
      add_messages(conv, 2)

      assert {:ok, result} = History.run(%{}, %{person_id: person.id})
      assert conversation_ids(result) == [conv.id]
    end

    test "ignores the LLM-supplied person_id param without skip_permissions" do
      me = create_person("chat_me@example.com")
      target = create_person("chat_target@example.com")
      my_conv = create_conversation(me.id)
      target_conv = create_conversation(target.id)
      add_messages(my_conv, 1)
      add_messages(target_conv, 1)

      assert {:ok, result} = History.run(%{person_id: target.id}, %{person_id: me.id})
      assert conversation_ids(result) == [my_conv.id]
      refute target_conv.id in conversation_ids(result)
    end

    test "accepts string ctx person_id" do
      person = create_person("chat_str@example.com")
      conv = create_conversation(person.id)
      add_messages(conv, 1)

      assert {:ok, result} = History.run(%{}, %{person_id: to_string(person.id)})
      assert conversation_ids(result) == [conv.id]
    end
  end

  # ── identity resolution — workflow path (actor) ──────────────────────

  describe "run/2 — workflow identity (actor person)" do
    test "uses actor.person.id with atom keys" do
      person = create_person("wf_atom@example.com")
      conv = create_conversation(person.id)
      add_messages(conv, 1)

      assert {:ok, result} = History.run(%{}, %{actor: %{person: %{id: person.id}}})
      assert conversation_ids(result) == [conv.id]
    end

    test "uses actor person id with string keys (JSONB round-trip)" do
      person = create_person("wf_string@example.com")
      conv = create_conversation(person.id)
      add_messages(conv, 1)

      assert {:ok, result} = History.run(%{}, %{actor: %{"person" => %{"id" => person.id}}})
      assert conversation_ids(result) == [conv.id]
    end

    test "actor person id wins over ctx person_id" do
      actor_person = create_person("wf_actor@example.com")
      ctx_person = create_person("wf_ctx@example.com")
      actor_conv = create_conversation(actor_person.id)
      _ctx_conv = create_conversation(ctx_person.id)
      add_messages(actor_conv, 1)

      assert {:ok, result} =
               History.run(%{}, %{
                 actor: %{person: %{id: actor_person.id}},
                 person_id: ctx_person.id
               })

      assert conversation_ids(result) == [actor_conv.id]
    end

    test "supports legacy flat actor person_id from persisted workflow events" do
      person = create_person("wf_legacy@example.com")
      conv = create_conversation(person.id)
      add_messages(conv, 1)

      assert {:ok, result} = History.run(%{}, %{actor: %{"person_id" => person.id}})
      assert conversation_ids(result) == [conv.id]
    end
  end

  # ── identity resolution — machine path (skip_permissions) ───────────

  describe "run/2 — machine identity (skip_permissions)" do
    test "honors params person_id under skip_permissions" do
      person = create_person("machine_target@example.com")
      conv = create_conversation(person.id)
      add_messages(conv, 2)

      assert {:ok, result} =
               History.run(%{person_id: person.id}, %{skip_permissions: true})

      assert conversation_ids(result) == [conv.id]
    end

    test "falls back to context identity when no params person_id" do
      person = create_person("machine_fallback@example.com")
      conv = create_conversation(person.id)
      add_messages(conv, 1)

      assert {:ok, result} =
               History.run(%{}, %{skip_permissions: true, person_id: person.id})

      assert conversation_ids(result) == [conv.id]
    end

    test "returns missing_person_id when no identity at all" do
      assert {:error, :missing_person_id} = History.run(%{}, %{skip_permissions: true})
    end

    test "returns missing_person_id for non-numeric person_id param" do
      assert {:error, :missing_person_id} =
               History.run(%{person_id: %{invalid: true}}, %{skip_permissions: true})
    end
  end

  # ── identity resolution — negatives ─────────────────────────────────

  describe "run/2 — unauthorized" do
    test "empty context grants nothing" do
      person = create_person("neg_empty@example.com")
      conv = create_conversation(person.id)
      add_messages(conv, 1)

      assert {:error, :unauthorized} = History.run(%{}, %{})
      assert {:error, :unauthorized} = History.run(%{person_id: person.id}, %{})
    end

    test "nil ctx person_id grants nothing" do
      assert {:error, :unauthorized} = History.run(%{}, %{person_id: nil})
    end

    test "nil actor grants nothing" do
      assert {:error, :unauthorized} = History.run(%{}, %{actor: nil})
    end

    test "empty-string person ids grant nothing" do
      assert {:error, :unauthorized} = History.run(%{}, %{person_id: ""})
      assert {:error, :unauthorized} = History.run(%{}, %{actor: %{person_id: ""}})
      assert {:error, :unauthorized} = History.run(%{person_id: ""}, %{person_id: ""})
    end

    test "skip_permissions false does not elevate the person_id param" do
      target = create_person("neg_target@example.com")
      conv = create_conversation(target.id)
      add_messages(conv, 1)

      assert {:error, :unauthorized} =
               History.run(%{person_id: target.id}, %{skip_permissions: false})
    end
  end

  # ── recall filters ───────────────────────────────────────────────────

  describe "run/2 — query filter" do
    test "finds conversations by message content" do
      person = create_person("q_content@example.com")
      hit = create_conversation(person.id)
      add_messages(hit, 1, "we decided to acquire Company X")
      miss = create_conversation(person.id)
      add_messages(miss, 1, "lunch plans")

      assert {:ok, result} = History.run(%{query: "Company X"}, %{person_id: person.id})
      assert conversation_ids(result) == [hit.id]
      refute miss.id in conversation_ids(result)
    end

    test "finds conversations by title" do
      person = create_person("q_title@example.com")
      hit = create_conversation(person.id, %{title: "Salary raise discussion"})
      add_messages(hit, 1)
      miss = create_conversation(person.id, %{title: "Standup"})
      add_messages(miss, 1)

      assert {:ok, result} = History.run(%{query: "salary"}, %{person_id: person.id})
      assert conversation_ids(result) == [hit.id]
    end

    test "never returns another person's matching conversation" do
      me = create_person("q_me@example.com")
      other = create_person("q_other@example.com")
      mine = create_conversation(me.id, %{title: "Project Atlas"})
      add_messages(mine, 1)
      theirs = create_conversation(other.id, %{title: "Project Atlas"})
      add_messages(theirs, 1)

      assert {:ok, result} = History.run(%{query: "Atlas"}, %{person_id: me.id})
      assert conversation_ids(result) == [mine.id]
    end
  end

  describe "run/2 — last_n_days and date filters" do
    test "last_n_days: 7 includes recent, excludes old" do
      person = create_person("p_week@example.com")
      now = DateTime.utc_now()

      recent = create_conversation(person.id)
      add_messages(recent, 1)
      :ok = set_updated_at(recent, DateTime.add(now, -2, :day))

      old = create_conversation(person.id)
      add_messages(old, 1)
      :ok = set_updated_at(old, DateTime.add(now, -30, :day))

      assert {:ok, result} = History.run(%{last_n_days: 7}, %{person_id: person.id})
      assert conversation_ids(result) == [recent.id]
    end

    test "from_date/to_date ISO strings bound the range inclusively" do
      person = create_person("p_iso@example.com")

      inside = create_conversation(person.id)
      add_messages(inside, 1)
      :ok = set_updated_at(inside, ~U[2026-06-03 12:00:00.000000Z])

      outside = create_conversation(person.id)
      add_messages(outside, 1)
      :ok = set_updated_at(outside, ~U[2026-05-20 12:00:00.000000Z])

      assert {:ok, result} =
               History.run(
                 %{from_date: "2026-06-01", to_date: "2026-06-05"},
                 %{person_id: person.id}
               )

      assert conversation_ids(result) == [inside.id]
    end

    test "last_n_days takes precedence over explicit dates" do
      person = create_person("p_precedence@example.com")
      now = DateTime.utc_now()

      old = create_conversation(person.id)
      add_messages(old, 1)
      :ok = set_updated_at(old, DateTime.add(now, -60, :day))

      # from_date alone would include it; last_n_days: 7 must exclude it
      assert {:ok, result} =
               History.run(
                 %{last_n_days: 7, from_date: "2000-01-01"},
                 %{person_id: person.id}
               )

      assert conversation_ids(result) == []
    end

    test "non-positive or non-integer last_n_days returns a validation error" do
      person = create_person("p_invalid@example.com")

      for bad <- [0, -3, "fortnight"] do
        assert {:error, message} =
                 History.run(%{last_n_days: bad}, %{person_id: person.id})

        assert message =~ "invalid last_n_days"
      end
    end

    test "invalid date string returns a validation error" do
      person = create_person("p_baddate@example.com")

      assert {:error, message} =
               History.run(%{from_date: "junk"}, %{person_id: person.id})

      assert message =~ "invalid date"
    end

    test "to_date can be provided without from_date" do
      person = create_person("p_todate@example.com")

      inside = create_conversation(person.id)
      add_messages(inside, 1)
      :ok = set_updated_at(inside, ~U[2026-06-03 12:00:00.000000Z])

      outside = create_conversation(person.id)
      add_messages(outside, 1)
      :ok = set_updated_at(outside, ~U[2026-06-07 12:00:00.000000Z])

      assert {:ok, result} = History.run(%{to_date: "2026-06-05"}, %{person_id: person.id})

      assert conversation_ids(result) == [inside.id]
    end

    test "non-string date values return a validation error" do
      person = create_person("p_badtypedate@example.com")

      assert {:error, message} =
               History.run(%{from_date: ~D[2026-06-01]}, %{person_id: person.id})

      assert message =~ "invalid date"
    end
  end

  # ── output shape and limits ──────────────────────────────────────────

  describe "run/2 — output shape" do
    test "groups messages under conversations with id, title and updated_at" do
      person = create_person("shape@example.com")
      conv = create_conversation(person.id, %{title: "Quarterly budget"})
      add_messages(conv, 2)

      assert {:ok, %{conversations: [entry]}} = History.run(%{}, %{person_id: person.id})
      assert entry.id == conv.id
      assert entry.title == "Quarterly budget"
      assert %DateTime{} = entry.updated_at
      assert [%{role: "user", content: _, inserted_at: _} | _] = entry.messages
      assert length(entry.messages) == 2
    end

    test "includes metadata for total and current message windows" do
      person = create_person("metadata@example.com")
      conv1 = create_conversation(person.id, %{title: "Window A"})
      conv2 = create_conversation(person.id, %{title: "Window B"})

      add_message(conv1, "user", "first user")
      add_message(conv1, "assistant", "first assistant")
      add_message(conv1, "user", "second user")
      add_message(conv2, "assistant", "second assistant")

      assert {:ok, result} =
               History.run(%{messages_per_conversation: 1}, %{person_id: person.id})

      assert result.metadata.total.messages == 4
      assert result.metadata.total.user_messages == 2
      assert result.metadata.total.assistant_messages == 2
      assert %DateTime{} = result.metadata.total.first_message_date
      assert %DateTime{} = result.metadata.total.last_message_date

      assert result.metadata.current_window.messages == 2
      assert result.metadata.current_window.user_messages == 1
      assert result.metadata.current_window.assistant_messages == 1
      assert %DateTime{} = result.metadata.current_window.first_message_date
      assert %DateTime{} = result.metadata.current_window.last_message_date
    end

    test "metadata total only includes conversations loaded by existing filters" do
      person = create_person("metadata_filter@example.com")
      hit = create_conversation(person.id, %{title: "Included topic"})
      miss = create_conversation(person.id, %{title: "Excluded topic"})

      add_messages(hit, 3, "included")
      add_messages(miss, 2, "excluded")

      assert {:ok, result} = History.run(%{query: "Included"}, %{person_id: person.id})

      assert conversation_ids(result) == [hit.id]
      assert result.metadata.total.messages == 3
      assert result.metadata.current_window.messages == 3
    end

    test "no filters returns most recent conversations (default limit 10)" do
      person = create_person("recent@example.com")

      for _ <- 1..12 do
        conv = create_conversation(person.id)
        add_messages(conv, 1)
      end

      assert {:ok, result} = History.run(%{}, %{person_id: person.id})
      assert length(result.conversations) == 10
    end

    test "conversation_limit caps conversations" do
      person = create_person("convlimit@example.com")

      for _ <- 1..4 do
        conv = create_conversation(person.id)
        add_messages(conv, 1)
      end

      assert {:ok, result} =
               History.run(%{conversation_limit: 2}, %{person_id: person.id})

      assert length(result.conversations) == 2
    end

    test "messages_per_conversation caps each conversation independently" do
      person = create_person("msglimit@example.com")
      conv1 = create_conversation(person.id)
      conv2 = create_conversation(person.id)
      add_messages(conv1, 10)
      add_messages(conv2, 10)

      assert {:ok, %{conversations: conversations}} =
               History.run(%{messages_per_conversation: 3}, %{person_id: person.id})

      assert Enum.all?(conversations, &(length(&1.messages) == 3))
    end

    test "person with no conversations gets an empty list (not unauthorized)" do
      person = create_person("noconv@example.com")

      assert {:ok, %{conversations: [], metadata: metadata}} =
               History.run(%{}, %{person_id: person.id})

      assert metadata.total == %{
               messages: 0,
               user_messages: 0,
               assistant_messages: 0,
               first_message_date: nil,
               last_message_date: nil
             }

      assert metadata.current_window == metadata.total
    end

    test "data-layer query failures return an action error" do
      person = create_person("badlimit@example.com")
      conv = create_conversation(person.id)
      add_messages(conv, 1)

      assert {:error, reason} =
               History.run(%{conversation_limit: "not-an-integer"}, %{person_id: person.id})

      assert reason =~ "cannot be cast to type :integer"
    end
  end
end
