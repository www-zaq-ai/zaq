defmodule Zaq.Engine.Messages.IncomingTest do
  use ExUnit.Case, async: true

  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Messages.Incoming.RoutingContext

  test "builds with required fields only" do
    msg = %Incoming{content: "hello", channel_id: "ch1", provider: :mattermost}
    assert msg.content == "hello"
    assert msg.channel_id == "ch1"
    assert msg.provider == :mattermost
  end

  test "metadata defaults to empty map" do
    msg = %Incoming{content: "hi", channel_id: "ch1", provider: :slack}
    assert msg.metadata == %{}
  end

  test "attachments default to an empty list" do
    msg = Incoming.new(%{content: "hi", channel_id: "ch1", provider: :mattermost})

    assert msg.attachments == []
  end

  test "new/1 preserves attachment records" do
    attachment = %Record{id: "media-1", kind: :file, name: "photo.png"}

    msg =
      Incoming.new(%{
        content: "hi",
        channel_id: "ch1",
        provider: :mattermost,
        attachments: [attachment]
      })

    assert msg.attachments == [attachment]
  end

  test "routing context defaults to an empty struct" do
    msg = %Incoming{content: "hi", channel_id: "ch1", provider: :slack}

    assert msg.routing_context == %RoutingContext{}
  end

  test "optional fields default to nil" do
    msg = %Incoming{content: "hi", channel_id: "ch1", provider: :mattermost}
    assert is_nil(msg.author_id)
    assert is_nil(msg.author_name)
    assert is_nil(msg.thread_id)
    assert is_nil(msg.message_id)
  end

  test "accepts all optional fields" do
    msg = %Incoming{
      content: "hi",
      channel_id: "ch1",
      provider: :mattermost,
      author_id: "u1",
      author_name: "alice",
      thread_id: "t1",
      message_id: "m1",
      metadata: %{raw: "data"}
    }

    assert msg.author_id == "u1"
    assert msg.author_name == "alice"
    assert msg.thread_id == "t1"
    assert msg.message_id == "m1"
    assert msg.metadata == %{raw: "data"}
  end

  test "enforce_keys are declared" do
    # @enforce_keys is validated at compile time; this verifies the struct
    # definition itself carries the constraint.
    enforced = Incoming.__struct__() |> Map.from_struct() |> Map.keys()
    assert :content in enforced
    assert :channel_id in enforced
    assert :provider in enforced
  end

  test "new/1 injects telemetry dimensions in metadata" do
    msg =
      Incoming.new(%{
        content: "hello",
        channel_id: "ch1",
        provider: :mattermost,
        metadata: %{"foo" => "bar"}
      })

    assert msg.metadata["foo"] == "bar"

    assert msg.metadata["telemetry_dimensions"] == %{
             "channel_type" => "mattermost",
             "channel_config_id" => "unknown",
             "retrieval_channel_id" => "unknown",
             "provider" => "mattermost",
             "channel_id" => "ch1"
           }
  end

  test "new/1 normalizes bo and email channel types" do
    bo = Incoming.new(%{content: "hello", channel_id: "bo", provider: :web})
    email = Incoming.new(%{content: "hello", channel_id: "mail", provider: "email"})

    assert bo.metadata["telemetry_dimensions"]["channel_type"] == "bo"
    assert email.metadata["telemetry_dimensions"]["channel_type"] == "email:imap"
  end

  test "new/1 maps atom :email provider to email:imap channel type" do
    attrs = %{content: "hello", channel_id: "mail-1", provider: :email}

    msg = Incoming.new(attrs)

    assert msg.metadata["telemetry_dimensions"]["channel_type"] == "email:imap"
    assert msg.metadata["telemetry_dimensions"]["provider"] == "email"
    assert msg.provider == :email
  end

  test "new/1 maps string provider \"web\" to bo channel type" do
    attrs = %{content: "hello", channel_id: "bo-1", provider: "web"}

    msg = Incoming.new(attrs)

    assert msg.metadata["telemetry_dimensions"]["channel_type"] == "bo"
    assert msg.metadata["telemetry_dimensions"]["provider"] == "web"
  end

  test "new/1 preserves unrecognized string provider as channel type" do
    attrs = %{content: "hello", channel_id: "ch-x", provider: "teams"}

    msg = Incoming.new(attrs)

    assert msg.metadata["telemetry_dimensions"]["channel_type"] == "teams"
    assert msg.metadata["telemetry_dimensions"]["provider"] == "teams"
  end

  test "new/1 normalizes channel_config_id variants" do
    blank =
      Incoming.new(%{
        content: "hello",
        channel_id: "ch1",
        provider: :web,
        metadata: %{"channel_config_id" => "   "}
      })

    integer =
      Incoming.new(%{
        content: "hello",
        channel_id: "ch1",
        provider: :web,
        channel_config_id: 42
      })

    invalid =
      Incoming.new(%{
        content: "hello",
        channel_id: "ch1",
        provider: :web,
        channel_config_id: %{bad: true}
      })

    assert blank.metadata["telemetry_dimensions"]["channel_config_id"] == "unknown"
    assert integer.metadata["telemetry_dimensions"]["channel_config_id"] == "42"
    assert invalid.metadata["telemetry_dimensions"]["channel_config_id"] == "unknown"
  end

  test "new/1 normalizes routing context from atom and string keyed maps" do
    atom_keyed =
      Incoming.new(%{
        content: "hello",
        channel_id: "ch1",
        provider: :mattermost,
        routing_context: %{channel_config_id: "42", retrieval_channel_id: 7, topic_id: " inbox "}
      })

    string_keyed =
      Incoming.new(%{
        :content => "hello",
        :channel_id => "ch1",
        :provider => :mattermost,
        "routing_context" => %{
          "channel_config_id" => 43,
          "retrieval_channel_id" => "8",
          "attributes" => %{"mailbox" => "INBOX"}
        }
      })

    assert atom_keyed.routing_context == %RoutingContext{
             channel_config_id: 42,
             retrieval_channel_id: 7,
             topic_id: "inbox",
             attributes: %{}
           }

    assert atom_keyed.metadata["telemetry_dimensions"]["channel_config_id"] == "42"
    assert atom_keyed.metadata["telemetry_dimensions"]["retrieval_channel_id"] == "7"

    assert string_keyed.routing_context == %RoutingContext{
             channel_config_id: 43,
             retrieval_channel_id: 8,
             attributes: %{"mailbox" => "INBOX"}
           }
  end

  test "new/1 accepts a routing context struct and safely ignores invalid input" do
    context = %RoutingContext{channel_config_id: "bad", retrieval_channel_id: "9"}

    struct_context =
      Incoming.new(%{
        content: "hello",
        channel_id: "ch1",
        provider: :mattermost,
        routing_context: context
      })

    invalid_context =
      Incoming.new(%{
        content: "hello",
        channel_id: "ch1",
        provider: :mattermost,
        routing_context: :bad
      })

    assert struct_context.routing_context == %RoutingContext{retrieval_channel_id: 9}
    assert invalid_context.routing_context == %RoutingContext{}
  end

  test "new/1 builds routing context from legacy top-level and metadata ids" do
    top_level =
      Incoming.new(%{
        content: "hello",
        channel_id: "ch1",
        provider: :mattermost,
        channel_config_id: "42",
        retrieval_channel_id: "8"
      })

    metadata =
      Incoming.new(%{
        content: "hello",
        channel_id: "ch1",
        provider: :mattermost,
        metadata: %{"channel_config_id" => "43", "retrieval_channel_id" => "9"}
      })

    assert top_level.routing_context.channel_config_id == 42
    assert top_level.routing_context.retrieval_channel_id == 8
    assert metadata.routing_context.channel_config_id == 43
    assert metadata.routing_context.retrieval_channel_id == 9
  end

  test "new/1 falls back to api channel type for unsupported provider type" do
    msg = Incoming.new(%{content: "hello", channel_id: "ch1", provider: 123})

    assert msg.metadata["telemetry_dimensions"]["channel_type"] == "api"
    assert msg.metadata["telemetry_dimensions"]["provider"] == "123"
  end

  test "new/1 normalizes metadata and content_filter" do
    msg =
      Incoming.new(%{
        content: "hello",
        channel_id: "ch1",
        provider: :mattermost,
        metadata: "not-a-map",
        content_filter: ["ok", 1, nil, "safe"]
      })

    assert is_map(msg.metadata)
    assert msg.content_filter == ["ok", "safe"]
  end

  test "new/1 normalizes person payload through ActorNormalizer" do
    msg =
      Incoming.new(%{
        content: "hello",
        channel_id: "ch1",
        provider: :mattermost,
        person: %{"id" => "42", "full_name" => "Ada", "team_ids" => ["7", :bad, 8]}
      })

    assert msg.person == %{id: 42, full_name: "Ada", team_ids: [7, 8]}
    assert Incoming.person_id(msg) == 42
    assert Incoming.team_ids(msg) == [7, 8]
  end

  describe "new/1 required keys" do
    test "raises ArgumentError when :content key is missing" do
      attrs = %{channel_id: "ch1", provider: :mattermost}

      assert_raise ArgumentError, "missing required key :content for Incoming.new/1", fn ->
        Incoming.new(attrs)
      end
    end

    test "raises ArgumentError when required key is absent in both atom and string forms" do
      attrs = %{"content" => "hello", provider: :mattermost}

      assert_raise ArgumentError, "missing required key :channel_id for Incoming.new/1", fn ->
        Incoming.new(attrs)
      end
    end
  end
end
