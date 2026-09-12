defmodule Zaq.People.IdentityResolverTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Accounts.PersonChannel
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.People.IdentityResolver

  alias Zaq.People.IdentityResolverTest.ErrorRouter
  alias Zaq.People.IdentityResolverTest.RaiseRouter

  defp incoming(overrides) do
    struct(
      %Incoming{
        content: "hello",
        channel_id: "C123",
        provider: :slack,
        author_id: "U123",
        author_name: "jane",
        is_dm: false,
        metadata: %{}
      },
      overrides
    )
  end

  defp complete_person_with_channel(channel_identifier, attrs) do
    {:ok, person} =
      People.create_person(
        Map.merge(%{full_name: "Jane Smith", email: "jane@example.com"}, attrs)
      )

    {:ok, channel} =
      People.add_channel(%{
        "person_id" => person.id,
        "platform" => "slack",
        "channel_identifier" => channel_identifier
      })

    {People.get_person_with_channels!(person.id), channel}
  end

  describe "resolve/2" do
    test "email variants touch the canonical row even when a legacy variant sorts first" do
      for phone <- [nil, "+15550123"] do
        email = if phone, do: "fast@example.com", else: "slow@example.com"
        {:ok, person} = People.create_person(%{full_name: "Email", email: email, phone: phone})
        [canonical] = People.list_person_channels(person.id)

        {:ok, canonical} =
          People.update_channel(canonical, %{weight: 1, last_interaction_at: nil})

        # Arrange legacy storage independently of the canonical changesets.
        legacy =
          Repo.insert!(%PersonChannel{
            person_id: person.id,
            platform: "email",
            channel_identifier: " " <> String.upcase(email) <> " ",
            weight: 0
          })

        msg = incoming(%{provider: :"email:imap", author_id: String.upcase(email), is_dm: true})
        assert {:ok, resolved} = IdentityResolver.resolve(msg, channels_router: ErrorRouter)
        assert resolved.id == person.id
        assert [untouched, touched] = People.list_person_channels(person.id)
        assert untouched == legacy
        assert touched.id == canonical.id
        assert touched.channel_identifier == email
        assert touched.last_interaction_at != nil
        assert {:ok, repeated} = IdentityResolver.resolve(msg, channels_router: ErrorRouter)
        assert repeated.id == person.id
        assert length(People.list_person_channels(person.id)) == 2
        assert People.get_channel(legacy.id) == legacy
      end
    end

    test "returns People error when slow path cannot create from an empty author id" do
      msg = incoming(%{author_id: "", author_name: nil})

      assert {:error, %Ecto.Changeset{}} =
               IdentityResolver.resolve(msg, channels_router: ErrorRouter)
    end

    test "enriches through default Channels.Api fetch_profile event" do
      expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{
                                                 next_hop: %{destination: :channels},
                                                 request: %{
                                                   provider: "slack",
                                                   author_id: "U_FETCH"
                                                 },
                                                 opts: [action: :fetch_profile]
                                               } = event ->
        %{event | response: {:ok, %{display_name: "Fetched Name", email: "fetched@example.com"}}}
      end)

      msg = incoming(%{author_id: "U_FETCH", author_name: nil})

      assert {:ok, person} = IdentityResolver.resolve(msg, [])
      loaded = People.get_person_with_channels!(person.id)

      assert loaded.full_name == "U_FETCH"
      assert loaded.email == nil
      assert hd(loaded.channels).channel_identifier == "U_FETCH"
    end

    test "succeeds when no matching channel is found on the matched person" do
      {:ok, person} =
        People.create_person(%{full_name: "Email Match", email: "email-match@example.com"})

      channel = People.list_person_channels(person.id) |> hd()
      {:ok, _deleted} = People.delete_channel(channel)

      msg =
        incoming(%{
          provider: :"email:imap",
          author_id: "email-match@example.com",
          author_name: nil
        })

      assert {:ok, resolved} = IdentityResolver.resolve(msg, channels_router: ErrorRouter)
      assert resolved.id == person.id

      channels = People.list_person_channels(person.id)

      assert length(channels) == 1
      assert hd(channels).channel_identifier == "email-match@example.com"
    end

    test "backfills dm_channel_id through default Channels.Api open_dm_channel event" do
      {_person, channel} =
        complete_person_with_channel("U_BACKFILL_DEFAULT", %{
          email: "backfill@example.com",
          phone: "+15550001"
        })

      assert is_nil(channel.dm_channel_id)

      expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{
                                                 next_hop: %{destination: :channels},
                                                 request: %{
                                                   provider: "slack",
                                                   author_id: "U_BACKFILL_DEFAULT"
                                                 },
                                                 opts: [action: :open_dm_channel]
                                               } = event ->
        %{event | response: {:ok, "DM_DEFAULT"}}
      end)

      msg = incoming(%{author_id: "U_BACKFILL_DEFAULT", is_dm: false})

      assert {:ok, person} = IdentityResolver.resolve(msg, [])
      loaded = People.get_person_with_channels!(person.id)
      channel = Enum.find(loaded.channels, &(&1.channel_identifier == "U_BACKFILL_DEFAULT"))

      assert channel.dm_channel_id == nil
    end

    test "falls back when channel id is empty" do
      expect(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{
                                                 next_hop: %{destination: :channels},
                                                 request: %{
                                                   provider: "slack",
                                                   author_id: "U_EMPTY_CHANNEL"
                                                 },
                                                 opts: [action: :fetch_profile]
                                               } = event ->
        %{event | response: {:error, :not_found}}
      end)

      msg = incoming(%{author_id: "U_EMPTY_CHANNEL", channel_id: "", is_dm: false})

      assert {:ok, person} = IdentityResolver.resolve(msg, [])
      loaded = People.get_person_with_channels!(person.id)

      assert Enum.any?(loaded.channels, &(&1.channel_identifier == "U_EMPTY_CHANNEL"))
    end
  end

  defmodule ErrorRouter do
    def fetch_profile(_platform, _author_id), do: {:error, :not_found}

    def open_dm_channel(_platform, _author_id), do: {:error, :not_found}
  end

  defmodule RaiseRouter do
    def fetch_profile(_platform, _author_id), do: raise("fetch_profile should not be called")

    def open_dm_channel(_platform, _author_id), do: raise("open_dm_channel should not be called")
  end
end
