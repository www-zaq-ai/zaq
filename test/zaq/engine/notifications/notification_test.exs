defmodule Zaq.Engine.Notifications.NotificationTest do
  use Zaq.DataCase, async: false

  import Ecto.Query

  @moduletag capture_log: true

  alias Zaq.Accounts.People
  alias Zaq.Accounts.PersonChannel
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Engine.Notifications
  alias Zaq.Engine.Notifications.{Notification, NotificationLog}
  alias Zaq.Repo

  defmodule NotificationConfig do
    def get(:zaq, :channels, _default) do
      %{
        email: %{bridge: Zaq.Channels.EmailBridge}
      }
    end
  end

  defmodule OkCommunicationBridge do
    def bridge_for(_provider), do: __MODULE__
    def fetch_connection_details(_provider), do: %{}

    def send_reply(%Outgoing{} = outgoing, _connection_details) do
      send(self(), {:delivered, outgoing.provider, outgoing.channel_id})
      :ok
    end
  end

  defmodule ErrorCommunicationBridge do
    def bridge_for(_provider), do: __MODULE__
    def fetch_connection_details(_provider), do: %{}
    def send_reply(%Outgoing{}, _connection_details), do: {:error, :delivery_failed}
  end

  defmodule UnknownAwareCommunicationBridge do
    def bridge_for("coverage_unknown" <> _), do: nil
    def bridge_for(_provider), do: __MODULE__
    def fetch_connection_details(_provider), do: %{}

    def send_reply(%Outgoing{} = outgoing, _connection_details) do
      send(self(), {:delivered, outgoing.provider, outgoing.channel_id})
      :ok
    end
  end

  defmodule NilCommunicationBridge do
    def bridge_for(_provider), do: __MODULE__
    def fetch_connection_details(_provider), do: %{}
    def send_reply(%Outgoing{}, _connection_details), do: nil
  end

  defmodule FirstFailCommunicationBridge do
    def bridge_for(_provider), do: __MODULE__
    def fetch_connection_details(_provider), do: %{}

    def send_reply(%Outgoing{channel_id: "first@example.com"}, _connection_details),
      do: {:error, :delivery_failed}

    def send_reply(%Outgoing{} = outgoing, _connection_details) do
      send(self(), {:delivered, outgoing.provider, outgoing.channel_id})
      :ok
    end
  end

  defmodule StaleStatusCommunicationBridge do
    import Ecto.Query

    alias Zaq.Engine.Messages.Outgoing
    alias Zaq.Engine.Notifications.NotificationLog
    alias Zaq.Repo

    def bridge_for(_provider), do: __MODULE__
    def fetch_connection_details(_provider), do: %{}

    def send_reply(%Outgoing{} = outgoing, _connection_details) do
      log =
        Repo.one!(
          from l in NotificationLog,
            order_by: [desc: l.id],
            limit: 1
        )

      {:ok, _} = NotificationLog.transition_status(log, "skipped")
      send(self(), {:delivered_after_stale_status, outgoing.provider, outgoing.channel_id})
      :ok
    end
  end

  defmodule StubNodeRouter do
    def dispatch(event) do
      api_module = Keyword.get(event.opts, :channels_api_module, Zaq.Channels.Api)
      action = Keyword.get(event.opts, :action, :invoke)

      api_module =
        if action == :bridge_available,
          do: Zaq.Engine.Notifications.NotificationTest.AlwaysAvailableChannelsApi,
          else: api_module

      api_module.handle_event(event, action, nil)
    end
  end

  defmodule AlwaysAvailableChannelsApi do
    alias Zaq.Channels.Api

    def handle_event(event, :bridge_available, _context), do: %{event | response: true}

    def handle_event(event, action, context),
      do: Api.handle_event(event, action, context)
  end

  @valid_attrs %{
    recipient_channels: [%{platform: "email:smtp", identifier: "test@example.com"}],
    sender: "system",
    subject: "Hello",
    body: "World"
  }

  # ---------------------------------------------------------------------------
  # Notification.build/1
  # ---------------------------------------------------------------------------

  describe "build/1 — valid inputs" do
    test "returns {:ok, %Notification{}} with all required fields" do
      assert {:ok, %Notification{} = n} = Notification.build(@valid_attrs)
      assert n.subject == "Hello"
      assert n.body == "World"
      assert n.sender == "system"
      assert length(n.recipient_channels) == 1
    end

    test "sender defaults to \"system\" when omitted" do
      attrs = Map.delete(@valid_attrs, :sender)
      assert {:ok, %Notification{sender: "system"}} = Notification.build(attrs)
    end

    test "empty recipient_channels is valid" do
      attrs = Map.put(@valid_attrs, :recipient_channels, [])
      assert {:ok, %Notification{recipient_channels: []}} = Notification.build(attrs)
    end

    test "metadata defaults to empty map" do
      assert {:ok, %Notification{metadata: %{}}} = Notification.build(@valid_attrs)
    end

    test "optional fields are nil by default" do
      assert {:ok, %Notification{recipient_name: nil, recipient_ref: nil, html_body: nil}} =
               Notification.build(@valid_attrs)
    end

    test "accepts all optional fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          recipient_name: "Alice",
          recipient_ref: {:user, 42},
          html_body: "<p>World</p>",
          metadata: %{foo: "bar"}
        })

      assert {:ok, n} = Notification.build(attrs)
      assert n.recipient_name == "Alice"
      assert n.recipient_ref == {:user, 42}
      assert n.html_body == "<p>World</p>"
      assert n.metadata == %{foo: "bar"}
    end

    test "multiple channels without preferred flag are all valid" do
      attrs = %{
        @valid_attrs
        | recipient_channels: [
            %{platform: "email:smtp", identifier: "a@b.com"},
            %{platform: "slack", identifier: "U01"}
          ]
      }

      assert {:ok, %Notification{}} = Notification.build(attrs)
    end
  end

  describe "build/1 — validation failures" do
    test "missing subject returns {:error, _}" do
      attrs = Map.delete(@valid_attrs, :subject)
      assert {:error, reason} = Notification.build(attrs)
      assert reason =~ "subject"
    end

    test "blank subject returns {:error, _}" do
      attrs = Map.put(@valid_attrs, :subject, "")
      assert {:error, reason} = Notification.build(attrs)
      assert reason =~ "subject"
    end

    test "missing body returns {:error, _}" do
      attrs = Map.delete(@valid_attrs, :body)
      assert {:error, reason} = Notification.build(attrs)
      assert reason =~ "body"
    end

    test "blank body returns {:error, _}" do
      attrs = Map.put(@valid_attrs, :body, "")
      assert {:error, reason} = Notification.build(attrs)
      assert reason =~ "body"
    end

    test "channel missing platform returns {:error, _}" do
      attrs = %{@valid_attrs | recipient_channels: [%{identifier: "U01"}]}
      assert {:error, reason} = Notification.build(attrs)
      assert reason =~ "platform"
    end

    test "channel missing identifier returns {:error, _}" do
      attrs = %{@valid_attrs | recipient_channels: [%{platform: "email:smtp"}]}
      assert {:error, reason} = Notification.build(attrs)
      assert reason =~ "identifier"
    end
  end

  # ---------------------------------------------------------------------------
  # Notifications.notify/1
  # ---------------------------------------------------------------------------

  describe "notify/1" do
    setup do
      Application.put_env(:zaq, :notifications_node_router_module, StubNodeRouter)

      on_exit(fn ->
        Application.delete_env(:zaq, :notifications_node_router_module)
      end)

      from(c in ChannelConfig,
        where: c.provider in ["email:smtp", "email:imap", "telegram", "unknown-platform"]
      )
      |> Repo.delete_all()

      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Email",
        provider: "email:smtp",
        kind: "retrieval",
        url: "smtp://localhost",
        token: "test-token",
        enabled: true
      })
      |> Repo.insert!()

      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "IMAP",
        provider: "email:imap",
        kind: "retrieval",
        url: "imap://localhost",
        token: "test-token",
        settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}},
        enabled: true
      })
      |> Repo.insert!()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(ChannelConfig, [
        %{
          name: "Unknown Platform",
          provider: "unknown-platform",
          kind: "retrieval",
          url: "https://unknown-platform.test",
          token: "test-token",
          enabled: true,
          inserted_at: now,
          updated_at: now
        }
      ])

      :ok
    end

    test "empty channels returns {:ok, :skipped}" do
      {:ok, n} =
        Notification.build(
          Map.merge(@valid_attrs, %{recipient_channels: [], recipient_name: "Alice"})
        )

      assert {:ok, %{status: :skipped, notification_log_id: nil}} =
               Notifications.notify(n, config: NotificationConfig)
    end

    test "non-empty channels with configured platform delivers inline and returns final channel" do
      {:ok, n} = Notification.build(@valid_attrs)

      assert {:ok,
              %{
                status: :sent,
                channel: "email:smtp",
                channel_identifier: "test@example.com",
                notification_log_id: log_id
              }} =
               Notifications.notify(n,
                 config: NotificationConfig,
                 channels_event_opts: [bridge_module: OkCommunicationBridge]
               )

      assert is_integer(log_id)
      assert_receive {:delivered, "email:smtp", "test@example.com"}

      reloaded = Repo.get!(NotificationLog, log_id)

      assert reloaded.status == "sent"

      assert Enum.map(
               reloaded.channels_tried,
               &Map.take(&1, ["platform", "identifier", "status"])
             ) == [
               %{"identifier" => "test@example.com", "platform" => "email:smtp", "status" => "ok"}
             ]
    end

    test "provider without a resolvable bridge fails that attempt and falls back to email" do
      provider = "coverage_unknown_#{System.unique_integer([:positive])}"
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(ChannelConfig, [
        %{
          name: "Coverage Unknown",
          provider: provider,
          kind: "retrieval",
          url: "https://#{provider}.test",
          token: "test-token",
          enabled: true,
          inserted_at: now,
          updated_at: now
        }
      ])

      {:ok, n} =
        Notification.build(%{
          @valid_attrs
          | recipient_channels: [
              %{platform: provider, identifier: "bad-platform"},
              %{platform: "email:smtp", identifier: "fallback@example.com"}
            ]
        })

      assert {:ok,
              %{
                status: :sent,
                channel: "email:smtp",
                channel_identifier: "fallback@example.com",
                notification_log_id: log_id
              }} =
               Notifications.notify(n,
                 config: NotificationConfig,
                 channels_event_opts: [bridge_module: UnknownAwareCommunicationBridge]
               )

      assert_receive {:delivered, "email:smtp", "fallback@example.com"}

      reloaded = Repo.get!(NotificationLog, log_id)

      assert reloaded.status == "sent"

      assert Enum.map(
               reloaded.channels_tried,
               &Map.take(&1, ["platform", "identifier", "status"])
             ) == [
               %{
                 "platform" => provider,
                 "identifier" => "bad-platform",
                 "status" => "error"
               },
               %{
                 "platform" => "email:smtp",
                 "identifier" => "fallback@example.com",
                 "status" => "ok"
               }
             ]
    end

    test "email:imap maps to email and delivers" do
      {:ok, n} =
        Notification.build(%{
          @valid_attrs
          | recipient_channels: [%{platform: "email:imap", identifier: "imap@example.com"}]
        })

      assert {:ok,
              %{
                status: :sent,
                channel: "email:imap",
                channel_identifier: "imap@example.com",
                notification_log_id: log_id
              }} =
               Notifications.notify(n,
                 config: NotificationConfig,
                 channels_event_opts: [bridge_module: OkCommunicationBridge]
               )

      assert_receive {:delivered, "email:imap", "imap@example.com"}

      reloaded = Repo.get!(NotificationLog, log_id)

      assert reloaded.status == "sent"

      assert Enum.map(
               reloaded.channels_tried,
               &Map.take(&1, ["platform", "identifier", "status"])
             ) == [
               %{
                 "platform" => "email:imap",
                 "identifier" => "imap@example.com",
                 "status" => "ok"
               }
             ]
    end

    test "telegram maps through channel bridge configuration and delivers" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert_all(ChannelConfig, [
        %{
          name: "Telegram",
          provider: "telegram",
          kind: "retrieval",
          url: "https://telegram.test",
          token: "test-token",
          enabled: true,
          inserted_at: now,
          updated_at: now
        }
      ])

      {:ok, n} =
        Notification.build(%{
          @valid_attrs
          | recipient_channels: [%{platform: "telegram", identifier: "chat-123"}]
        })

      assert {:ok,
              %{
                status: :sent,
                channel: "telegram",
                channel_identifier: "chat-123",
                notification_log_id: log_id
              }} =
               Notifications.notify(n,
                 config: NotificationConfig,
                 channels_event_opts: [bridge_module: OkCommunicationBridge]
               )

      assert_receive {:delivered, "telegram", "chat-123"}

      reloaded = Repo.get!(NotificationLog, log_id)
      assert reloaded.status == "sent"

      assert Enum.map(
               reloaded.channels_tried,
               &Map.take(&1, ["platform", "identifier", "status"])
             ) == [
               %{"platform" => "telegram", "identifier" => "chat-123", "status" => "ok"}
             ]
    end

    test "delivery succeeds but stale status prevents mark_sent from transitioning" do
      {:ok, n} = Notification.build(@valid_attrs)

      assert {:ok,
              %{
                status: :sent,
                notification_log_id: log_id,
                channel: "email:smtp",
                channel_identifier: "test@example.com",
                reason: :stale_record
              }} =
               Notifications.notify(n,
                 config: NotificationConfig,
                 channels_event_opts: [bridge_module: StaleStatusCommunicationBridge]
               )

      assert_receive {:delivered_after_stale_status, "email:smtp", "test@example.com"}

      reloaded = Repo.get!(NotificationLog, log_id)

      assert reloaded.status == "skipped"

      assert Enum.map(
               reloaded.channels_tried,
               &Map.take(&1, ["platform", "identifier", "status"])
             ) == [
               %{"platform" => "email:smtp", "identifier" => "test@example.com", "status" => "ok"}
             ]
    end

    test "non-empty channels with no configured platform returns {:ok, :skipped}" do
      {:ok, n} =
        Notification.build(%{
          @valid_attrs
          | recipient_channels: [%{platform: "mattermost", identifier: "U123"}]
        })

      assert {:ok, %{status: :skipped}} = Notifications.notify(n, config: NotificationConfig)

      reloaded =
        Repo.one(
          from l in NotificationLog,
            order_by: [desc: l.id],
            limit: 1
        )

      assert reloaded.status == "skipped"
      assert reloaded.payload["subject"] == "Hello"

      assert [%{"platform" => "mattermost", "status" => "error"}] =
               Enum.map(reloaded.channels_tried, &Map.take(&1, ["platform", "status"]))
    end

    test "channels are dispatched in the order provided and stop on first success" do
      {:ok, n} =
        Notification.build(%{
          @valid_attrs
          | recipient_channels: [
              %{platform: "email:smtp", identifier: "first@example.com"},
              %{platform: "email:smtp", identifier: "second@example.com"}
            ]
        })

      assert {:ok, %{status: :sent, channel_identifier: "first@example.com"}} =
               Notifications.notify(n,
                 config: NotificationConfig,
                 channels_event_opts: [bridge_module: OkCommunicationBridge]
               )

      assert_receive {:delivered, "email:smtp", "first@example.com"}
      refute_received {:delivered, "email:smtp", "second@example.com"}
    end

    test "first channel fails, second succeeds and returns the successful channel" do
      {:ok, n} =
        Notification.build(%{
          @valid_attrs
          | recipient_channels: [
              %{platform: "email:smtp", identifier: "first@example.com"},
              %{platform: "email:smtp", identifier: "second@example.com"}
            ]
        })

      assert {:ok, %{status: :sent, channel_identifier: "second@example.com"}} =
               Notifications.notify(n,
                 config: NotificationConfig,
                 channels_event_opts: [bridge_module: FirstFailCommunicationBridge]
               )

      reloaded = Repo.one(from l in NotificationLog, order_by: [desc: l.id], limit: 1)

      assert Enum.map(reloaded.channels_tried, &Map.take(&1, ["identifier", "status"])) == [
               %{"identifier" => "first@example.com", "status" => "error"},
               %{"identifier" => "second@example.com", "status" => "ok"}
             ]
    end

    test "all channels fail returns an error result and marks the log failed" do
      {:ok, n} = Notification.build(@valid_attrs)

      assert {:error, %{status: :failed, notification_log_id: log_id}} =
               Notifications.notify(n,
                 config: NotificationConfig,
                 channels_event_opts: [bridge_module: ErrorCommunicationBridge]
               )

      reloaded = Repo.get!(NotificationLog, log_id)
      assert reloaded.status == "failed"

      assert [%{"status" => "error", "identifier" => "test@example.com"}] =
               reloaded.channels_tried
    end

    test "unexpected dispatch response is treated as a failed channel attempt" do
      {:ok, n} = Notification.build(@valid_attrs)

      assert {:error, %{status: :failed, notification_log_id: log_id}} =
               Notifications.notify(n,
                 config: NotificationConfig,
                 channels_event_opts: [bridge_module: NilCommunicationBridge]
               )

      reloaded = Repo.get!(NotificationLog, log_id)
      assert reloaded.status == "failed"

      assert [%{"status" => "error", "error" => error, "identifier" => "test@example.com"}] =
               reloaded.channels_tried

      assert error =~ "unexpected_response"
    end

    test "rejects a plain map — only %Notification{} accepted" do
      assert_raise FunctionClauseError, fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Notifications, :notify, [%{subject: "S", body: "B", recipient_channels: []}])
      end
    end
  end

  describe "notify_person/3" do
    setup do
      Application.put_env(:zaq, :notifications_node_router_module, StubNodeRouter)

      on_exit(fn ->
        Application.delete_env(:zaq, :notifications_node_router_module)
      end)

      from(c in ChannelConfig, where: c.provider in ["email:smtp", "mattermost"])
      |> Repo.delete_all()

      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Email",
        provider: "email:smtp",
        kind: "retrieval",
        url: "smtp://localhost",
        token: "test-token",
        enabled: true
      })
      |> Repo.insert!()

      :ok
    end

    test "returns an error when the person does not exist" do
      assert {:error, "person_not_found:" <> _} =
               Notifications.notify_person(999_999, %{subject: "Hello", message: "Body"})
    end

    test "skips when the person has no channels" do
      {:ok, person} = People.create_person(%{full_name: "No Channels"})

      assert {:ok, %{status: :skipped, notification_log_id: nil}} =
               Notifications.notify_person(person.id, %{subject: "Hello", message: "Body"})
    end

    test "resolves person channels in preferred fallback order" do
      {:ok, person} = People.create_person(%{full_name: "Multi Email"})

      Repo.insert!(%PersonChannel{
        person_id: person.id,
        platform: "email",
        channel_identifier: "second@example.com",
        weight: 20
      })

      Repo.insert!(%PersonChannel{
        person_id: person.id,
        platform: "email",
        channel_identifier: "first@example.com",
        weight: 10
      })

      assert {:ok, %{status: :sent, channel_identifier: "second@example.com"}} =
               Notifications.notify_person(person.id, %{subject: "Hello", message: "Body"},
                 config: NotificationConfig,
                 channels_event_opts: [bridge_module: FirstFailCommunicationBridge]
               )

      reloaded = Repo.one(from l in NotificationLog, order_by: [desc: l.id], limit: 1)

      assert Enum.map(reloaded.channels_tried, &Map.take(&1, ["identifier", "status"])) == [
               %{"identifier" => "first@example.com", "status" => "error"},
               %{"identifier" => "second@example.com", "status" => "ok"}
             ]
    end

    test "uses dm_channel_id as the delivery identifier when present" do
      {:ok, person} = People.create_person(%{full_name: "DM Person", email: nil})

      Repo.insert!(%PersonChannel{
        person_id: person.id,
        platform: "email",
        channel_identifier: "person@example.com",
        dm_channel_id: "stored-dm-channel-1",
        weight: 0
      })

      assert {:ok, %{status: :sent, channel_identifier: "stored-dm-channel-1"}} =
               Notifications.notify_person(person.id, %{subject: "Hello", message: "Body"},
                 config: NotificationConfig,
                 channels_event_opts: [bridge_module: OkCommunicationBridge]
               )
    end

    test "falls back to channel_identifier when dm_channel_id is missing" do
      {:ok, person} = People.create_person(%{full_name: "DM Person", email: nil})

      Repo.insert!(%PersonChannel{
        person_id: person.id,
        platform: "email",
        channel_identifier: "person@example.com",
        weight: 0
      })

      assert {:ok, %{status: :sent, channel_identifier: "person@example.com"}} =
               Notifications.notify_person(person.id, %{subject: "Hello", message: "Body"},
                 config: NotificationConfig,
                 channels_event_opts: [bridge_module: OkCommunicationBridge]
               )
    end
  end
end
