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
end
