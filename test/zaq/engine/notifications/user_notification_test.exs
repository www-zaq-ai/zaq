defmodule Zaq.Engine.Notifications.UserNotificationTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  import Ecto.Changeset
  import Ecto.Query

  alias Zaq.Accounts.People
  alias Zaq.Accounts.User
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Engine.Notifications
  alias Zaq.Engine.Notifications.NotificationLog
  alias Zaq.Permissions
  alias Zaq.Repo

  defmodule Router do
    def dispatch(event) do
      case event.opts[:action] do
        :bridge_available ->
          %{event | response: true}

        :conversation_identity ->
          %{event | response: nil}

        :deliver_outgoing ->
          send(self(), {:deliver_outgoing, event.request})
          %{event | response: {:ok, %{message_id: "msg-#{event.request.channel_id}"}}}
      end
    end
  end

  defmodule FakeAccounts do
    def get_user(id) when is_integer(id),
      do: %User{id: id, username: "user-#{id}", email: "u#{id}@example.com"}

    def get_user(_id), do: nil
  end

  setup do
    Application.put_env(:zaq, :notifications_node_router_module, Router)

    on_exit(fn ->
      Application.delete_env(:zaq, :notifications_node_router_module)
    end)

    from(c in ChannelConfig, where: c.provider == "email:smtp")
    |> Repo.delete_all()

    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "SMTP",
      provider: "email:smtp",
      kind: "retrieval",
      url: "smtp://localhost",
      token: "test-token",
      enabled: true
    })
    |> Repo.insert!()

    :ok
  end

  defp person_fixture(attrs) do
    unique = System.unique_integer([:positive])

    params =
      Map.merge(
        %{
          full_name: "Person #{unique}",
          email: "person_#{unique}@example.com",
          phone: "+1555#{unique}",
          role: "member",
          status: "active"
        },
        attrs
      )

    {:ok, person} = People.create_person(params)
    person
  end

  describe "notify_user/3" do
    test "dispatches BO user email through the Channels deliver_outgoing boundary" do
      user = user_fixture(%{username: "ops_user", email: "ops@example.com"})

      assert {:ok,
              %{
                status: :sent,
                channel: "email:smtp",
                channel_identifier: "ops@example.com",
                notification_log_id: log_id
              }} = Notifications.notify_user(user.id, %{subject: "Ops", message: "Check queue"})

      assert_received {:deliver_outgoing, %Outgoing{} = outgoing}
      assert outgoing.provider == "email:smtp"
      assert outgoing.channel_id == "ops@example.com"
      assert outgoing.body == "Check queue"
      assert outgoing.metadata["subject"] == "Ops"

      log = Repo.get!(NotificationLog, log_id)
      assert log.recipient_ref_type == "user"
      assert log.recipient_ref_id == user.id
      assert log.recipient_name == "ops_user"
    end

    test "missing email is skipped without attempting Channels delivery" do
      user = user_fixture(%{username: "email_missing", email: "missing@example.com"})
      user = user |> change(email: nil) |> Repo.update!()

      assert {:ok, %{status: :skipped, reason: :no_recipient_channels}} =
               Notifications.notify_user(user.id, %{subject: "Ops", message: "Check queue"})

      refute_received {:deliver_outgoing, _outgoing}
    end
  end

  describe "notify_users/3" do
    test "attempts every unique user and summarizes sent, skipped, and failed results" do
      sent = user_fixture(%{username: "sent_user", email: "sent@example.com"})
      skipped = user_fixture(%{username: "skip_user", email: "skip@example.com"})
      skipped = skipped |> change(email: nil) |> Repo.update!()
      missing_id = 1_000_000_000 + System.unique_integer([:positive])

      assert {:ok,
              %{
                requested_count: 4,
                recipient_count: 3,
                sent_count: 1,
                skipped_count: 1,
                failed_count: 1,
                results: results
              }} =
               Notifications.notify_users(
                 [sent.id, skipped.id, sent.id, missing_id],
                 %{subject: "Same", message: "Same body"},
                 skip_permissions: true
               )

      assert Enum.map(results, & &1.user_id) == [sent.id, skipped.id, missing_id]
      assert Enum.find(results, &(&1.user_id == sent.id)).status == :sent
      assert Enum.find(results, &(&1.user_id == skipped.id)).status == :skipped
      assert Enum.find(results, &(&1.user_id == missing_id)).status == :failed

      assert_received {:deliver_outgoing, %Outgoing{channel_id: "sent@example.com"}}
      refute_received {:deliver_outgoing, %Outgoing{channel_id: "skip@example.com"}}
    end

    property "counts add up to unique recipients and duplicates are attempted once" do
      check all(
              user_ids <- StreamData.list_of(StreamData.integer(1..5), max_length: 8),
              max_runs: 10
            ) do
        assert {:ok, summary} =
                 Notifications.notify_users(user_ids, %{subject: "Hello", message: "Body"},
                   accounts_module: FakeAccounts,
                   skip_permissions: true
                 )

        unique_count = user_ids |> Enum.uniq() |> length()

        assert summary.requested_count == length(user_ids)
        assert summary.recipient_count == unique_count
        assert summary.sent_count + summary.skipped_count + summary.failed_count == unique_count
        assert summary.sent_count == unique_count

        assert summary.results |> Enum.map(& &1.user_id) |> Enum.uniq() |> length() ==
                 unique_count
      end
    end

    test "requires read permission on every requested user" do
      actor = person_fixture(%{full_name: "Notification Actor"})
      allowed = user_fixture(%{username: "allowed_notify", email: "allowed@example.com"})
      denied = user_fixture(%{username: "denied_notify", email: "denied@example.com"})

      {:ok, _permission} =
        Permissions.grant(allowed, %{person_id: actor.id, access_rights: ["read"]})

      assert {:error, :unauthorized} =
               Notifications.notify_users(
                 [allowed.id, denied.id],
                 %{subject: "Restricted", message: "Body"},
                 actor: %{person: %{id: actor.id, team_ids: []}}
               )

      refute_received {:deliver_outgoing, _outgoing}

      assert {:ok, %{sent_count: 1, recipient_count: 1}} =
               Notifications.notify_users(
                 [allowed.id],
                 %{subject: "Restricted", message: "Body"},
                 actor: %{person: %{id: actor.id, team_ids: []}}
               )

      assert_received {:deliver_outgoing, %Outgoing{channel_id: "allowed@example.com"}}
    end

    test "rejects malformed user ids before account lookup" do
      assert {:error, {:invalid_request, :user_ids}} =
               Notifications.notify_users(
                 ["not-an-id"],
                 %{subject: "Bad", message: "Body"},
                 skip_permissions: true
               )

      refute_received {:deliver_outgoing, _outgoing}
    end
  end
end
