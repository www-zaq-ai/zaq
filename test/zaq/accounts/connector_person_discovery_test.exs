defmodule Zaq.Accounts.ConnectorPersonDiscoveryTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Accounts.{People, Person, PersonChannel}
  alias Zaq.Channels.ChannelConfig

  setup do
    configs = for host <- ["one", "two"], do: config(host)
    %{configs: configs}
  end

  property "normalized email identifies one Person across connector and opaque-ID variations", %{
    configs: [first, second]
  } do
    check all(
            name <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
            same_id? <- StreamData.boolean(),
            max_runs: 20
          ) do
      suffix = System.unique_integer([:positive])
      email = "#{String.downcase(name)}#{suffix}@example.com"
      attrs = %{channel_id: "user-#{suffix}", channel_config_id: first.id, email: email}
      {:ok, person} = People.find_or_create_from_channel("mattermost", attrs)
      second_id = if same_id?, do: attrs.channel_id, else: "other-#{suffix}"

      other = %{
        attrs
        | channel_config_id: second.id,
          channel_id: second_id,
          email: "  #{String.upcase(email)}  "
      }

      for _ <- 1..2 do
        assert {:ok, resolved} = People.find_or_create_from_channel("mattermost", other)
        assert resolved.id == person.id
      end

      assert Repo.aggregate(from(p in Person, where: p.email == ^email), :count) == 1

      links =
        Repo.all(
          from c in PersonChannel, where: c.person_id == ^person.id and c.platform == "mattermost"
        )

      assert MapSet.new(Enum.map(links, &{&1.channel_config_id, &1.channel_identifier})) ==
               MapSet.new([{first.id, attrs.channel_id}, {second.id, second_id}])
    end
  end

  test "email-less identical opaque IDs stay independent", %{configs: configs} do
    people =
      Enum.map(configs, fn config ->
        {:ok, person} =
          People.find_or_create_from_channel("mattermost", %{
            channel_id: "same",
            channel_config_id: config.id
          })

        person.id
      end)

    assert length(Enum.uniq(people)) == 2
  end

  test "two Mattermost bots on one server share a native identity without email" do
    configs = [config("shared"), config("shared")]

    [first, second] =
      Enum.map(configs, fn config ->
        assert {:ok, person} =
                 People.find_or_create_from_channel("mattermost", %{
                   channel_id: "native-user",
                   channel_config_id: config.id
                 })

        person
      end)

    assert first.id == second.id
    assert length(People.list_person_channels(first.id)) == 2
  end

  test "Telegram user identity is shared across bots" do
    configs =
      for name <- ["bot-a", "bot-b"] do
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: name,
          provider: "telegram",
          kind: "retrieval",
          token: "fixture-token",
          url: "https://api.telegram.org"
        })
        |> Repo.insert!()
      end

    people =
      Enum.map(configs, fn config ->
        assert {:ok, person} =
                 People.find_or_create_from_channel("telegram", %{
                   channel_id: "12345",
                   channel_config_id: config.id
                 })

        person
      end)

    assert Enum.uniq_by(people, & &1.id) |> length() == 1
  end

  test "retargeting a server connector does not reinterpret a stored identity" do
    config = config("original")
    attrs = %{channel_id: "native", channel_config_id: config.id}
    assert {:ok, person} = People.find_or_create_from_channel("mattermost", attrs)
    config |> ChannelConfig.changeset(%{url: "https://different.example.com"}) |> Repo.update!()

    assert {:error, :identity_scope_changed} =
             People.match_by_channel("mattermost", "native", config.id)

    assert {:error, :identity_scope_changed} =
             People.find_or_create_from_channel("mattermost", attrs)

    assert People.get_person!(person.id)
  end

  test "explicit Person merge transfers native identities to the survivor" do
    first = config("merge")
    second = config("merge")

    assert {:ok, owner} =
             People.find_or_create_from_channel("mattermost", %{
               channel_id: "native-merge",
               channel_config_id: first.id
             })

    assert {:ok, survivor} = People.create_person(%{full_name: "Survivor"})
    assert {:ok, _} = People.merge_persons(survivor.id, owner.id)

    assert {:ok, resolved} =
             People.find_or_create_from_channel("mattermost", %{
               channel_id: "native-merge",
               channel_config_id: second.id
             })

    assert resolved.id == survivor.id
  end

  test "conflicting linked and email owners fail atomically", %{configs: [config | _]} do
    {:ok, owner} =
      People.find_or_create_from_channel("mattermost", %{
        channel_id: "linked",
        channel_config_id: config.id
      })

    {:ok, other} = People.create_person(%{full_name: "Other", email: "other@example.com"})

    assert {:error, %Ecto.Changeset{}} =
             People.find_or_create_from_channel(
               "mattermost",
               %{channel_id: "linked", channel_config_id: config.id, email: other.email}
             )

    assert {:ok, unchanged} = People.match_by_channel("mattermost", "linked", config.id)
    assert unchanged.id == owner.id
    assert unchanged.email == nil
    assert Repo.aggregate(Person, :count) == 2
  end

  test "concurrent connector discovery reuses the global email owner", %{configs: configs} do
    results =
      configs
      |> Enum.map(fn config ->
        Task.async(fn ->
          People.find_or_create_from_channel(
            "mattermost",
            %{channel_id: "same", channel_config_id: config.id, email: "shared@example.com"}
          )
        end)
      end)
      |> Enum.map(&Task.await(&1, 30_000))

    assert [{:ok, first}, {:ok, second}] = results
    assert first.id == second.id
    assert Repo.aggregate(Person, :count) == 1

    assert Repo.aggregate(from(c in PersonChannel, where: c.platform == "mattermost"), :count) ==
             2
  end

  defp config(host) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: host,
      provider: "mattermost",
      kind: "retrieval",
      url: "https://#{host}.example.com",
      token: "fixture-token",
      enabled: false
    })
    |> Repo.insert!()
  end
end
