defmodule Zaq.Agent.Tools.People.UpdatePersonTest do
  use Zaq.DataCase, async: false

  alias Jido.Action.Runtime
  alias Jido.Action.Schema
  alias Zaq.Accounts.People
  alias Zaq.Agent.Tools.People.UpdatePerson
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Api

  defmodule RoutedNodeRouter do
    def dispatch(event), do: Api.handle_event(event, :people_command, nil)
  end

  defmodule ErrorRouter do
    def dispatch(event), do: %{event | response: {:error, "people unavailable"}}
  end

  defmodule UnexpectedRouter do
    def dispatch(event), do: %{event | response: {:unexpected, :shape}}
  end

  @ctx %{node_router: RoutedNodeRouter}

  setup do
    {:ok, _telegram} =
      ChannelConfig.upsert_by_provider("telegram", %{
        name: "Telegram",
        kind: "retrieval",
        url: "https://telegram.example.com",
        token: "telegram-token",
        enabled: true
      })

    {:ok, _mattermost} =
      ChannelConfig.upsert_by_provider("mattermost", %{
        name: "Mattermost",
        kind: "retrieval",
        url: "https://mattermost.example.com",
        token: "mattermost-token",
        enabled: true
      })

    :ok
  end

  describe "Jido schemas" do
    test "non-map params pass through pre-validation" do
      assert {:ok, "raw"} = UpdatePerson.on_before_validate_params("raw")
      assert {:ok, [:not, :a, :map]} = UpdatePerson.on_before_validate_params([:not, :a, :map])
    end

    test "direct channel validation handles default arg and non-object channels" do
      assert :ok =
               UpdatePerson.validate_channel(%{
                 platform: "telegram",
                 channel_identifier: "@valid"
               })

      assert {:error, "channel must be an object"} = UpdatePerson.validate_channel("not-a-map")
    end

    test "params and output schemas are valid Zoi schemas" do
      assert Schema.schema_type(UpdatePerson.schema()) == :zoi
      assert Schema.schema_type(UpdatePerson.output_schema()) == :zoi
      assert :ok = Schema.validate_config_schema(UpdatePerson.schema())
      assert :ok = Schema.validate_config_schema(UpdatePerson.output_schema())
    end

    test "runtime validation accepts update and merge fields" do
      assert {:ok, params} =
               Runtime.validate_params(
                 %{
                   person_id: 1,
                   attrs: %{full_name: "Updated"},
                   channels: [%{platform: "telegram", channel_identifier: "@updated"}],
                   merge_with_person_id: 2,
                   merge_precedence: "person"
                 },
                 UpdatePerson
               )

      assert params.person_id == 1
      assert params.merge_precedence == "person"
    end

    test "tool schema exposes explicit person attr and channel fields" do
      tool = UpdatePerson.to_tool()

      assert get_in(tool.parameters_schema, [:properties, :attrs, :properties, :full_name, :type]) in [
               :string,
               "string"
             ]

      assert get_in(tool.parameters_schema, [
               :properties,
               :channels,
               :items,
               :properties,
               :platform,
               :type
             ]) in [:string, "string"]

      assert get_in(tool.parameters_schema, [
               :properties,
               :channels,
               :items,
               :properties,
               :channel_identifier,
               :type
             ]) in [:string, "string"]
    end

    test "runtime validation requires platform and channel_identifier when adding a channel" do
      assert {:error, _reason} =
               Runtime.validate_params(
                 %{person_id: 1, channels: [%{platform: "telegram"}]},
                 UpdatePerson
               )

      assert {:error, _reason} =
               Runtime.validate_params(
                 %{person_id: 1, channels: [%{channel_identifier: "@missing-platform"}]},
                 UpdatePerson
               )

      assert {:ok, params} =
               Runtime.validate_params(
                 %{person_id: 1, channels: [%{id: 10, display_name: "Existing"}]},
                 UpdatePerson
               )

      assert [%{id: 10}] = params.channels
    end

    test "runtime validation rejects platforms without an enabled communication channel" do
      assert {:error, _reason} =
               Runtime.validate_params(
                 %{
                   person_id: 1,
                   channels: [%{platform: "slack", channel_identifier: "U123"}]
                 },
                 UpdatePerson
               )
    end
  end

  test "returns an explicit error for non-map run params" do
    assert {:error, "params must be a map"} = UpdatePerson.run("bad", @ctx)
  end

  test "formats binary router errors unchanged" do
    assert {:error, "people unavailable"} =
             UpdatePerson.run(%{person_id: 123}, %{node_router: ErrorRouter})
  end

  test "inspects unexpected router responses" do
    assert {:error, "{:unexpected, :shape}"} =
             UpdatePerson.run(%{person_id: 123}, %{node_router: UnexpectedRouter})
  end

  test "updates person fields and adds a channel through Engine routing" do
    {:ok, person} =
      People.create_person(%{full_name: "Original", email: "original@example.com"})

    assert {:ok, %{person: payload, merged: false, merge_precedence: nil}} =
             UpdatePerson.run(
               %{
                 person_id: person.id,
                 attrs: %{full_name: "Updated"},
                 channels: [%{platform: "telegram", channel_identifier: "@updated"}]
               },
               @ctx
             )

    assert payload.full_name == "Updated"
    assert Enum.any?(payload.channels, &(&1.platform == "telegram"))
  end

  test "edits an existing channel through Engine routing" do
    {:ok, person} = People.create_person(%{full_name: "Channel", email: "channel@example.com"})

    {:ok, channel} =
      People.add_channel(%{
        person_id: person.id,
        platform: "mattermost",
        channel_identifier: "old-id"
      })

    assert {:ok, %{person: payload}} =
             UpdatePerson.run(
               %{
                 person_id: person.id,
                 channels: [%{id: channel.id, channel_identifier: "new-id"}]
               },
               @ctx
             )

    assert Enum.any?(
             payload.channels,
             &(&1.id == channel.id and &1.channel_identifier == "new-id")
           )
  end

  test "merges with other person when other precedence is requested" do
    {:ok, person} = People.create_person(%{full_name: "Loser", email: "loser@example.com"})
    {:ok, other} = People.create_person(%{full_name: "Winner", email: "winner@example.com"})

    assert {:ok, %{person: payload, merged: true, merge_precedence: "other"}} =
             UpdatePerson.run(
               %{
                 person_id: person.id,
                 channels: [%{platform: "telegram", channel_identifier: "@loser"}],
                 merge_with_person_id: other.id,
                 merge_precedence: "other"
               },
               @ctx
             )

    assert payload.id == other.id
    assert payload.full_name == "Winner"
    assert Enum.any?(payload.channels, &(&1.channel_identifier == "@loser"))
    assert is_nil(People.get_person(person.id))
  end
end
