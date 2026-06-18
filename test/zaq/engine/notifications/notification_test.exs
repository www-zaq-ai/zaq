defmodule Zaq.Engine.Notifications.NotificationTest do
  use Zaq.DataCase, async: true
  use Oban.Testing, repo: Zaq.Repo

  import Ecto.Query

  @moduletag capture_log: true

  alias Zaq.Accounts.People
  alias Zaq.Accounts.PersonChannel
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Notifications
  alias Zaq.Engine.Notifications.{DispatchWorker, Notification, NotificationLog}
  alias Zaq.Repo

  defmodule NotificationConfig do
    def get(:zaq, :channels, _default) do
      %{
        :"email:imap" => %{bridge: Zaq.Channels.EmailBridge},
        email: %{bridge: Zaq.Channels.EmailBridge}
      }
    end
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
      from(c in ChannelConfig, where: c.provider == "email:smtp")
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

    test "empty channels returns {:ok, :skipped}" do
      {:ok, n} =
        Notification.build(
          Map.merge(@valid_attrs, %{recipient_channels: [], recipient_name: "Alice"})
        )

      assert {:ok, :skipped} = Notifications.notify(n, config: NotificationConfig)
    end

    test "non-empty channels with configured platform returns {:ok, :dispatched}" do
      {:ok, n} = Notification.build(@valid_attrs)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, :dispatched} = Notifications.notify(n, config: NotificationConfig)
        assert_enqueued(worker: DispatchWorker)
      end)
    end

    test "non-empty channels with no configured platform returns {:ok, :skipped}" do
      {:ok, n} =
        Notification.build(%{
          @valid_attrs
          | recipient_channels: [%{platform: "mattermost", identifier: "U123"}]
        })

      assert {:ok, :skipped} = Notifications.notify(n, config: NotificationConfig)

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

    test "channels are dispatched in the order provided — no internal sorting" do
      {:ok, n} =
        Notification.build(%{
          @valid_attrs
          | recipient_channels: [
              %{platform: "email:smtp", identifier: "first@example.com"},
              %{platform: "email:smtp", identifier: "second@example.com"}
            ]
        })

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, :dispatched} = Notifications.notify(n, config: NotificationConfig)
        [job] = all_enqueued(worker: DispatchWorker)
        channels = job.args["channels"]
        assert hd(channels)["identifier"] == "first@example.com"
      end)
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
      from(c in ChannelConfig, where: c.provider == "email:smtp")
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

      assert {:ok, :skipped} =
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

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, :dispatched} =
                 Notifications.notify_person(person.id, %{subject: "Hello", message: "Body"})

        [job] = all_enqueued(worker: DispatchWorker)

        assert [
                 %{"platform" => "email:smtp", "identifier" => "first@example.com"},
                 %{"platform" => "email:smtp", "identifier" => "second@example.com"}
               ] = job.args["channels"]
      end)
    end
  end
end
