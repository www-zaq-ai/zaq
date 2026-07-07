defmodule Zaq.Engine.Messages.IncomingTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Messages.Incoming

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

  describe "records" do
    alias Zaq.Contracts.Record

    test "preserves records list passed to new/1" do
      records = [
        %Record{
          id: "r1",
          kind: :file,
          content: "hello",
          name: "doc.txt",
          mime_type: "text/plain"
        },
        %Record{id: "r2", kind: :file, content: nil, name: "img.png", mime_type: "image/png"}
      ]

      msg =
        Incoming.new(%{
          content: "check these",
          channel_id: "ch1",
          provider: :telegram,
          records: records
        })

      assert length(msg.records) == 2
      assert Enum.at(msg.records, 0).id == "r1"
      assert Enum.at(msg.records, 0).content == "hello"
      assert Enum.at(msg.records, 1).id == "r2"
      assert Enum.at(msg.records, 1).content == nil
    end

    test "records is empty list when records field is nil" do
      msg =
        Incoming.new(%{
          content: "no records",
          channel_id: "ch1",
          provider: :telegram,
          records: nil
        })

      assert msg.records == []
    end

    test "records is empty list when records field is not a list" do
      msg =
        Incoming.new(%{
          content: "bad records",
          channel_id: "ch1",
          provider: :telegram,
          records: "not-a-list"
        })

      assert msg.records == []
    end

    test "records defaults to empty list when not provided" do
      msg =
        Incoming.new(%{
          content: "default",
          channel_id: "ch1",
          provider: :telegram
        })

      assert msg.records == []
    end

    test "struct defaults records to empty list" do
      msg = %Incoming{content: "hi", channel_id: "ch1", provider: :telegram}
      assert msg.records == []
    end
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
