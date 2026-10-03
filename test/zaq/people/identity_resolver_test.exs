defmodule Zaq.People.IdentityResolverTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Accounts.PersonChannel
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Messages.Incoming.RoutingContext
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

  describe "resolve_audience/2" do
    test "discovers visible recipients across inbox links without including hidden recipients" do
      smtp =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "SMTP for email audience",
          provider: "email:smtp",
          kind: "retrieval",
          url: "https://example.invalid",
          token: "fixture-token"
        })
        |> Repo.insert!()

      imap =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "IMAP audience",
          provider: "email:imap",
          kind: "retrieval",
          url: "https://example.invalid",
          token: "fixture-token",
          settings: %{
            "imap" => %{"selected_mailboxes" => ["INBOX"], "smtp_config_id" => smtp.id}
          }
        })
        |> Repo.insert!()

      visible = person_email_channel("visible@example.com", imap.id)
      hidden = person_email_channel("hidden@example.com", imap.id)
      different = person_email_channel("different@example.com", smtp.id)
      legacy = person_email_channel("legacy@example.com", nil)

      {:ok, canonical} =
        People.create_person(%{full_name: "CC Person", email: "canonical@example.com"})

      email = %Incoming{
        content: "hello",
        channel_id: "sender@example.com",
        provider: :"email:imap",
        author_id: "sender@example.com",
        routing_context: %RoutingContext{
          channel_config_id: imap.id,
          audience: %Zaq.Engine.Messages.Incoming.Audience{
            platform: "email",
            sender: "sender@example.com",
            recipients: [
              "VISIBLE@EXAMPLE.COM",
              "visible@example.com",
              "different@example.com",
              "legacy@example.com",
              "canonical@example.com",
              "unknown@example.com"
            ]
          }
        },
        metadata: %{"email" => %{"bcc" => "hidden@example.com"}}
      }

      assert {:ok, recipient_ids} =
               IdentityResolver.resolve_audience(email, imap.id)

      assert {:ok, unknown} = People.match_by_channel("email", "unknown@example.com", imap.id)

      assert recipient_ids ==
               Enum.sort([visible.id, different.id, legacy.id, canonical.id, unknown.id])

      refute hidden.id in recipient_ids
      assert {:ok, %{id: id}} = People.match_by_channel("email", "canonical@example.com", imap.id)
      assert id == canonical.id

      assert {:error, :connector_mismatch} =
               IdentityResolver.resolve_audience(email, smtp.id)

      assert {:error, :invalid_recipient_evidence} =
               IdentityResolver.resolve_audience(
                 %{email | routing_context: %{email.routing_context | audience: nil}},
                 imap.id
               )

      mismatched_sender = %{
        email
        | routing_context: %{
            email.routing_context
            | audience: %{email.routing_context.audience | sender: "spoof@example.com"}
          }
      }

      assert {:error, :invalid_recipient_evidence} =
               IdentityResolver.resolve_audience(mismatched_sender, imap.id)

      assert {:ok, []} =
               IdentityResolver.resolve_audience(
                 %{
                   email
                   | routing_context: %{
                       email.routing_context
                       | audience: %{email.routing_context.audience | recipients: []}
                     }
                 },
                 imap.id
               )

      {:ok, _disabled} =
        imap
        |> ChannelConfig.changeset(%{enabled: false})
        |> Repo.update()

      assert {:error, :connector_mismatch} =
               IdentityResolver.resolve_audience(email, imap.id)
    end
  end

  defp person_email_channel(identifier, config_id) do
    {:ok, person} = People.create_person(%{full_name: identifier})

    {:ok, _} =
      People.add_channel(%{
        "person_id" => person.id,
        "platform" => "email",
        "channel_identifier" => identifier,
        "channel_config_id" => config_id
      })

    person
  end

  describe "resolve/2" do
    test "rejects a claimed connector whose provider differs from the message" do
      {person, _channel} = complete_person_with_channel("U123", %{})

      config =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "Unrelated connector",
          provider: "mattermost",
          kind: "retrieval",
          url: "https://example.invalid",
          token: "fixture-token",
          enabled: false
        })
        |> Repo.insert!()

      message =
        incoming(%{
          routing_context: %RoutingContext{channel_config_id: config.id}
        })

      assert {:error, :connector_mismatch} =
               IdentityResolver.resolve(message, channels_router: ErrorRouter)

      assert {:ok, matched} = People.match_by_channel("slack", "U123")
      assert matched.id == person.id
    end

    test "accepts a retrieval connector matching the message provider" do
      config =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "Slack identity fixture",
          provider: "slack",
          kind: "retrieval",
          url: "https://example.invalid",
          token: "fixture-token",
          enabled: false
        })
        |> Repo.insert!()

      message = incoming(%{routing_context: %RoutingContext{channel_config_id: config.id}})

      assert {:ok, %{id: id}} = IdentityResolver.resolve(message, channels_router: ErrorRouter)
      assert is_integer(id)

      assert [%PersonChannel{channel_config_id: config_id}] =
               People.list_person_channels(id)

      assert config_id == config.id
    end

    test "sole connector links a pre-existing unscoped provider author without creating a Person" do
      {person, legacy} = complete_person_with_channel("U123", %{phone: "+15551234567"})

      config =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "Only Slack connector",
          provider: "slack",
          kind: "retrieval",
          url: "https://example.invalid",
          token: "fixture-token",
          enabled: true
        })
        |> Repo.insert!()

      assert {:ok, resolved} =
               IdentityResolver.resolve(
                 incoming(%{
                   is_dm: true,
                   routing_context: %RoutingContext{channel_config_id: config.id}
                 }),
                 channels_router: RaiseRouter
               )

      assert resolved.id == person.id
      assert People.get_channel(legacy.id).channel_config_id == config.id
      assert {:error, :not_found} = People.match_by_channel("slack", "U123")
    end

    test "multiple connectors never claim an unscoped author by opaque ID" do
      {legacy_person, legacy} = complete_person_with_channel("U123", %{})

      configs =
        for name <- ["Workspace A", "Workspace B"] do
          %ChannelConfig{}
          |> ChannelConfig.changeset(%{
            name: name,
            provider: "slack",
            kind: "retrieval",
            url: "https://example.invalid",
            token: "fixture-token",
            enabled: true
          })
          |> Repo.insert!()
        end

      [first, second] = configs

      assert {:ok, different} =
               IdentityResolver.resolve(
                 incoming(%{routing_context: %RoutingContext{channel_config_id: second.id}}),
                 channels_router: ErrorRouter
               )

      assert different.id != legacy_person.id
      assert People.get_channel(legacy.id).channel_config_id == nil
      assert {:error, :not_found} = People.match_by_channel("slack", "U123", first.id)
      assert {:ok, matched} = People.match_by_channel("slack", "U123", second.id)
      assert matched.id == different.id
    end

    test "an archived connector prevents a new same-provider account from claiming a legacy author" do
      {legacy_person, legacy} = complete_person_with_channel("U123", %{})

      old =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "Older Slack account",
          provider: "slack",
          kind: "retrieval",
          url: "https://example.invalid",
          token: "fixture-token",
          enabled: true
        })
        |> Repo.insert!()

      assert {:ok, _archived} = ChannelConfig.archive(old)

      replacement =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "Replacement Slack account",
          provider: "slack",
          kind: "retrieval",
          url: "https://example.invalid",
          token: "fixture-token",
          enabled: true
        })
        |> Repo.insert!()

      assert {:ok, newcomer} =
               IdentityResolver.resolve(
                 incoming(%{routing_context: %RoutingContext{channel_config_id: replacement.id}}),
                 channels_router: ErrorRouter
               )

      assert newcomer.id != legacy_person.id
      assert People.get_channel(legacy.id).channel_config_id == nil
      assert {:ok, matched} = People.match_by_channel("slack", "U123", replacement.id)
      assert matched.id == newcomer.id
    end

    test "archived connector cannot resolve a new incoming author" do
      config =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "Archived ingress",
          provider: "slack",
          kind: "retrieval",
          url: "https://example.invalid",
          token: "fixture-token",
          enabled: false
        })
        |> Repo.insert!()

      {:ok, _} = ChannelConfig.archive(config)

      assert {:error, :connector_mismatch} =
               IdentityResolver.resolve(
                 incoming(%{routing_context: %RoutingContext{channel_config_id: config.id}}),
                 channels_router: ErrorRouter
               )
    end

    test "a different connector cannot resolve a linked author with the same opaque ID" do
      first =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "First connector",
          provider: "slack",
          kind: "retrieval",
          url: "https://example.invalid",
          token: "fixture-token",
          enabled: false
        })
        |> Repo.insert!()

      {:ok, person} =
        IdentityResolver.resolve(
          incoming(%{routing_context: %RoutingContext{channel_config_id: first.id}}),
          channels_router: ErrorRouter
        )

      assert {:ok, resolved} = People.match_by_channel("slack", "U123", first.id)
      assert resolved.id == person.id
      assert {:error, :not_found} = People.match_by_channel("slack", "U123", first.id + 1)
      assert {:error, :not_found} = People.match_by_channel("slack", "U123")

      second =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "Second connector",
          provider: "slack",
          kind: "retrieval",
          url: "https://another.example.invalid",
          token: "fixture-token",
          enabled: false
        })
        |> Repo.insert!()

      assert {:ok, second_person} =
               IdentityResolver.resolve(
                 incoming(%{routing_context: %RoutingContext{channel_config_id: second.id}}),
                 channels_router: ErrorRouter
               )

      assert second_person.id != person.id
      assert {:ok, matched} = People.match_by_channel("slack", "U123", second.id)
      assert matched.id == second_person.id
      assert {:error, :not_found} = People.match_by_channel("slack", "U123")
    end

    test "concurrent discovery of one connector author resolves to one Person" do
      config =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "Concurrent connector",
          provider: "slack",
          kind: "retrieval",
          url: "https://example.invalid",
          token: "fixture-token",
          enabled: false
        })
        |> Repo.insert!()

      attrs = %{"channel_id" => "concurrent-user", "channel_config_id" => config.id}

      results =
        for _ <- 1..2 do
          Task.async(fn -> People.find_or_create_from_channel("slack", attrs) end)
        end
        |> Enum.map(&Task.await(&1, 30_000))

      assert [{:ok, first}, {:ok, second}] = results
      assert first.id == second.id

      assert [%PersonChannel{channel_config_id: config_id}] =
               People.list_person_channels(first.id)

      assert config_id == config.id
    end

    test "deleting a connector cannot silently turn its scoped identities into legacy identities" do
      config =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "Bound connector",
          provider: "slack",
          kind: "retrieval",
          url: "https://example.invalid",
          token: "fixture-token",
          enabled: false
        })
        |> Repo.insert!()

      assert {:ok, person} =
               IdentityResolver.resolve(
                 incoming(%{routing_context: %RoutingContext{channel_config_id: config.id}}),
                 channels_router: ErrorRouter
               )

      assert {:error, :protected} =
               Repo.transaction(fn ->
                 result =
                   config
                   |> Ecto.Changeset.change()
                   |> Ecto.Changeset.foreign_key_constraint(:id,
                     name: :channels_channel_config_id_fkey
                   )
                   |> Repo.delete()

                 assert {:error, %Ecto.Changeset{}} = result
                 Repo.rollback(:protected)
               end)

      assert {:ok, same_person} = People.match_by_channel("slack", "U123", config.id)
      assert same_person.id == person.id
      assert {:error, :not_found} = People.match_by_channel("slack", "U123")
    end

    test "accepts an IMAP retrieval connector for canonical email authors" do
      config =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "IMAP identity fixture",
          provider: "email:imap",
          kind: "retrieval",
          url: "imap.example.invalid",
          token: "fixture-token",
          settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}},
          enabled: false
        })
        |> Repo.insert!()

      message =
        incoming(%{
          provider: :"email:imap",
          author_id: "author@example.invalid",
          routing_context: %RoutingContext{
            channel_config_id: config.id,
            identity_platform: "email"
          }
        })

      assert {:ok, %{id: id}} = IdentityResolver.resolve(message, channels_router: ErrorRouter)
      assert is_integer(id)
    end

    test "email resolution touches the canonical row on fast and slow paths" do
      for phone <- [nil, "+15550123"] do
        email = if phone, do: "fast@example.com", else: "slow@example.com"
        {:ok, person} = People.create_person(%{full_name: "Email", email: email, phone: phone})
        [canonical] = People.list_person_channels(person.id)

        {:ok, canonical} =
          People.update_channel(canonical, %{weight: 1, last_interaction_at: nil})

        msg =
          incoming(%{
            provider: :"email:imap",
            author_id: String.upcase(email),
            is_dm: true,
            routing_context: %RoutingContext{identity_platform: "email"}
          })

        assert {:ok, resolved} = IdentityResolver.resolve(msg, channels_router: ErrorRouter)
        assert resolved.id == person.id
        assert [touched] = People.list_person_channels(person.id)
        assert touched.id == canonical.id
        assert touched.channel_identifier == email
        assert touched.last_interaction_at != nil
        assert {:ok, repeated} = IdentityResolver.resolve(msg, channels_router: ErrorRouter)
        assert repeated.id == person.id
        assert [same] = People.list_person_channels(person.id)
        assert same.id == canonical.id
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
