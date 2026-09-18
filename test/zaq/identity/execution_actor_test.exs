defmodule Zaq.Identity.ExecutionActorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Identity.ExecutionActor

  test "event normalization validates raw declarations before enrichment" do
    incoming = %Incoming{content: "hello", channel_id: "c", provider: :web, person: %{id: 42}}

    assert {:ok, %{person: %{id: 42}, provider: :web}} =
             ExecutionActor.from_event_request(%{actor: nil, request: incoming})

    assert {:ok, %{person: %{id: 43}}} =
             ExecutionActor.from_event_request(%{actor: %{person: %{id: 43}}, request: incoming})

    for actor <- [%{"person" => %{"id" => 2}, person: %{id: 1}}, %{person: nil}] do
      assert {:error, :invalid_execution_actor} =
               ExecutionActor.from_event_request(%{actor: actor, request: incoming})
    end

    assert {:error, :invalid_execution_actor} =
             ExecutionActor.from_event_request(%{actor: false, request: incoming})

    assert {:error, :invalid_execution_actor} =
             ExecutionActor.from_event_request(%{
               request: %{incoming | person: %{"id" => 2, id: 1}}
             })

    assert {:error, :missing_execution_actor} = ExecutionActor.from_event_request(%{})

    assert {:ok, %{kind: :system, subject: "cron"}} =
             ExecutionActor.from_event_request(%{
               "actor" => %{"kind" => "system", "subject" => "cron"}
             })
  end

  test "distinguishes missing from invalid without manufacturing an identity" do
    assert ExecutionActor.validate(nil) == {:error, :missing_execution_actor}
    assert ExecutionActor.identity(nil) == {:error, :missing_execution_actor}

    for actor <- [
          %{},
          [],
          "actor",
          42,
          %{id: 1},
          %{user_id: 1},
          %{person: nil},
          %{person: %{id: "bad"}, person_id: 4},
          %{person: %{id: 4}, person_id: 5},
          %{person: %{id: 4}, kind: :system, subject: "cron"},
          %{kind: :system, subject: " "},
          %{kind: :unknown, subject: "x"},
          %{kind: :anonymous},
          %{kind: :system, subject: 3},
          %{person_id: "bad", kind: :system, subject: "x"},
          %{person: %{"id" => 2, id: 1}},
          %{"kind" => "anonymous", kind: :system, subject: "x"},
          %{"person" => %{"id" => 2}, person: %{id: 1}}
        ] do
      assert ExecutionActor.validate(actor) == {:error, :invalid_execution_actor}, inspect(actor)
      assert ExecutionActor.identity(actor) == {:error, :invalid_execution_actor}
    end
  end

  test "normalizes legacy and JSON Person identity while preserving metadata" do
    actor = %{
      "person" => %{"id" => " 42 ", "team_ids" => ["2", "bad"], "custom" => "kept"},
      "person_id" => 42,
      "provider" => "web",
      "trace" => %{scope: "one"}
    }

    assert {:ok, canonical} = ExecutionActor.validate(actor)
    assert canonical.person.id == 42
    assert canonical.person.team_ids == [2]
    assert canonical.person["custom"] == "kept"
    assert canonical["trace"] == %{scope: "one"}
    assert ExecutionActor.identity(canonical) == {:ok, {:person, 42}}
    assert {:ok, %{person: %{id: -1}}} = ExecutionActor.validate(%{person_id: "-1"})
    assert {:ok, %{person: %{id: 0}}} = ExecutionActor.validate(%{person: %{id: 0}})
  end

  test "accepts every explicit origin in atom and JSON form" do
    for kind <- [:bo_user, :channel_subject, :anonymous, :system] do
      actor = %{kind: kind, subject: "origin:42", name: "display"}
      assert ExecutionActor.validate(actor) == {:ok, actor}

      assert ExecutionActor.identity(Jason.decode!(Jason.encode!(actor))) ==
               {:ok, {kind, "origin:42"}}
    end
  end

  test "accepts equal key aliases and rejects conflicts in nested and legacy fields" do
    actor = %{"person" => %{"id" => 42, id: 42}, person: %{"id" => 42, id: 42}}
    assert {:ok, {:person, 42}} = ExecutionActor.identity(actor)

    for actor <- [
          %{"person_id" => 2, person_id: 1},
          %{person: %{"team_ids" => [2], id: 42, team_ids: [1]}},
          %{person: %{}, kind: :anonymous, subject: "session"},
          %{kind: :system, subject: <<255>>},
          %{person: %{id: ""}},
          %{person: %{id: 1.5}}
        ] do
      assert {:error, :invalid_execution_actor} = ExecutionActor.validate(actor)
    end
  end

  property "conflicting legacy Person identity can never fall back to either declaration" do
    check all(id <- integer(), delta <- positive_integer()) do
      actor = %{person: %{id: id}, person_id: to_string(id + delta)}
      assert ExecutionActor.identity(actor) == {:error, :invalid_execution_actor}
    end
  end

  property "Person normalization is idempotent and identity ignores metadata and scope" do
    check all(id <- integer(), name <- string(:alphanumeric), scope <- string(:alphanumeric)) do
      actor = %{"person" => %{"id" => to_string(id), "full_name" => name}, "scope" => scope}
      assert {:ok, canonical} = ExecutionActor.validate(actor)
      assert ExecutionActor.validate(canonical) == {:ok, canonical}
      assert ExecutionActor.identity(actor) == {:ok, {:person, id}}
      assert ExecutionActor.identity(Map.put(canonical, :scope, "other")) == {:ok, {:person, id}}
    end
  end

  property "explicit origins retain identity through normalization and metadata changes" do
    check all(
            kind <- member_of([:bo_user, :channel_subject, :anonymous, :system]),
            subject <- string(:alphanumeric, min_length: 1),
            scope <- integer()
          ) do
      actor = %{"kind" => Atom.to_string(kind), "subject" => subject, "scope" => scope}
      assert {:ok, canonical} = ExecutionActor.validate(actor)
      assert ExecutionActor.validate(canonical) == {:ok, canonical}

      assert ExecutionActor.identity(Map.put(canonical, :name, "changed")) ==
               {:ok, {kind, subject}}
    end
  end
end
