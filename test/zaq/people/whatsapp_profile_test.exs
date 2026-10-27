defmodule Zaq.People.WhatsAppProfileTest do
  use Zaq.DataCase, async: false

  alias Amarula.Protocol.Signal.LidMappingFileStore
  alias Jido.Chat.WhatsApp.Adapter
  alias Zaq.Accounts.People
  alias Zaq.Channels.Bridge
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.People.IdentityResolver

  test "a profile phone links a new WhatsApp identity to the existing person" do
    {config, _conn} = connection()

    assert {:ok, existing} =
             People.create_person(%{full_name: "Directory Person", phone: "+15551234567"})

    assert {:ok, resolved} =
             IdentityResolver.resolve(
               incoming(config, "15551234567@s.whatsapp.net", "Sender Name"),
               []
             )

    assert resolved.id == existing.id
    assert resolved.full_name == "Directory Person"
    assert resolved.phone == existing.phone
    assert [channel] = resolved.channels
    assert channel.channel_config_id == config.id
    assert channel.channel_identifier == "15551234567@s.whatsapp.net"
    assert channel.phone == existing.phone
  end

  test "phone JIDs populate the directory and preserve edited name and phone" do
    {config, _conn} = connection()
    incoming = incoming(config, "15551234567:4@s.whatsapp.net", "Sender Name")
    assert {:ok, person} = IdentityResolver.resolve(incoming, [])
    assert person.full_name == "Sender Name"
    assert person.phone == "+15551234567"
    assert [channel] = person.channels
    assert channel.phone == person.phone

    assert {:ok, _} =
             People.update_person(person, %{
               full_name: "Directory @ Name",
               phone: "+15550000000",
               email: "directory@example.com"
             })

    assert {:ok, same} = IdentityResolver.resolve(incoming, [])
    assert same.id == person.id
    assert same.full_name == "Directory @ Name"
    assert same.phone == "+15550000000"
  end

  test "mapped LID phones populate both the person and channel" do
    {config, conn} = connection()
    lid = "1234567890@lid"

    assert {1, _} =
             LidMappingFileStore.store_mappings(Amarula.Connection.get_conn(conn), [
               {lid, "15551234567@s.whatsapp.net"}
             ])

    assert {:ok, person} = IdentityResolver.resolve(incoming(config, lid, "Sender Name"), [])
    assert person.phone == "+15551234567"
    assert [channel] = person.channels
    assert channel.phone == person.phone
  end

  test "absent and placeholder push names do not prevent Person creation" do
    {config, _} = connection()

    for {name, index} <- Enum.with_index([nil, "", " ", "~", " ~ "]) do
      jid = "1555123456#{index}@s.whatsapp.net"
      assert {:ok, person} = IdentityResolver.resolve(incoming(config, jid, name), [])
      assert person.full_name == jid
      assert person.phone == "+1555123456#{index}"
    end
  end

  test "LID phone enrichment is connection scoped and can arrive after the first message" do
    {first, conn} = connection()
    {second, second_conn} = connection()
    lid = "1234567890@lid"
    assert {:ok, person} = IdentityResolver.resolve(incoming(first, lid, nil), [])
    assert is_nil(person.phone)

    assert {1, _} =
             LidMappingFileStore.store_mappings(Amarula.Connection.get_conn(conn), [
               {lid, "15551234567@s.whatsapp.net"}
             ])

    assert {:ok, updated} = IdentityResolver.resolve(incoming(first, lid, "Sender Name"), [])
    assert updated.id == person.id
    assert updated.full_name == "Sender Name"
    assert updated.phone == "+15551234567"

    assert {:ok, shared} = IdentityResolver.resolve(incoming(second, lid, "Other Account"), [])
    assert shared.id == person.id
    assert shared.phone == updated.phone
    assert length(shared.channels) == 2

    assert {:ok, profile} = Adapter.get_user(lid, conn: second_conn)
    assert is_nil(profile.metadata.phone)
  end

  test "the same phone JID shares one person across connectors" do
    people =
      for _ <- 1..2 do
        {config, _} = connection()
        incoming = incoming(config, "15551234567@s.whatsapp.net", "Same Name")
        assert {:ok, person} = IdentityResolver.resolve(incoming, [])
        assert {:ok, repeated} = IdentityResolver.resolve(incoming, [])
        assert repeated.id == person.id
        assert repeated.phone == "+15551234567"
        person
      end

    assert [first, second] = people
    assert first.id == second.id
    assert length(second.channels) == 2
  end

  test "the same LID shares one person across connectors without a phone" do
    {first, _} = connection()
    {second, _} = connection()
    lid = "179976359915606@lid"

    assert {:ok, person} = IdentityResolver.resolve(incoming(first, lid, "Jad"), [])
    assert {:ok, shared} = IdentityResolver.resolve(incoming(second, lid, "Jad"), [])
    assert shared.id == person.id
    assert is_nil(shared.phone)
    assert length(shared.channels) == 2
    assert Enum.uniq(Enum.map(shared.channels, & &1.person_identity_id)) |> length() == 1

    assert MapSet.new(Enum.map(shared.channels, & &1.channel_config_id)) ==
             MapSet.new([first.id, second.id])

    assert {:ok, repeated} = IdentityResolver.resolve(incoming(second, lid, "Jad"), [])
    assert repeated.id == person.id
    assert length(repeated.channels) == 2
  end

  test "different LIDs with the same name remain different people" do
    {first, _} = connection()
    {second, _} = connection()
    assert {:ok, person} = IdentityResolver.resolve(incoming(first, "111111111@lid", "Jad"), [])
    assert {:ok, other} = IdentityResolver.resolve(incoming(second, "222222222@lid", "Jad"), [])
    refute other.id == person.id
  end

  defp connection do
    config = Zaq.WhatsAppFixtures.connector()

    profile = Bridge.fetch_connection_details_for_config(config).profile
    assert {:ok, conn} = Amarula.Testing.start_offline(profile: profile)
    on_exit(fn -> Amarula.stop(conn) end)
    {config, conn}
  end

  defp incoming(config, sender, name) do
    assert {:ok, chat} =
             Adapter.transform_incoming(%{
               id: Ecto.UUID.generate(),
               channel_jid: "120363000000000@g.us",
               from_jid: sender,
               pushname: name,
               text: "hello"
             })

    JidoChatBridge.to_internal(chat, config)
  end
end
