defmodule Zaq.Engine.Notifications.NotificationTest do
  use Zaq.DataCase, async: true
  use Oban.Testing, repo: Zaq.Repo

  @moduletag capture_log: true

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Notifications
  alias Zaq.Engine.Notifications.{DispatchWorker, Notification}
  alias Zaq.Repo

  @valid_attrs %{
    recipient_channels: [%{platform: "email", identifier: "test@example.com", preferred: true}],
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

    test "single preferred: true channel is valid" do
      attrs = %{
        @valid_attrs
        | recipient_channels: [
            %{platform: "email", identifier: "a@b.com", preferred: true},
            %{platform: "slack", identifier: "U01", preferred: false}
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

    test "two preferred: true channels returns {:error, _}" do
      attrs = %{
        @valid_attrs
        | recipient_channels: [
            %{platform: "email", identifier: "a@b.com", preferred: true},
            %{platform: "slack", identifier: "U01", preferred: true}
          ]
      }

      assert {:error, reason} = Notification.build(attrs)
      assert reason =~ "preferred"
    end
  end

  # ---------------------------------------------------------------------------
  # Notifications.notify/1
  # ---------------------------------------------------------------------------

  describe "notify/1" do
    setup do
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Email",
        provider: "email",
        kind: "retrieval",
        url: "smtp://localhost",
        token: "test-token",
        enabled: true
      })
      |> Repo.insert!()

      :ok
    end

    test "empty channels logs :skipped and returns {:ok, :skipped}" do
      {:ok, n} = Notification.build(%{@valid_attrs | recipient_channels: []})
      assert {:ok, :skipped} = Notifications.notify(n)
    end

    test "non-empty channels with configured platform returns {:ok, :dispatched}" do
      {:ok, n} = Notification.build(@valid_attrs)

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, :dispatched} = Notifications.notify(n)
        assert_enqueued(worker: DispatchWorker)
      end)
    end

    test "non-empty channels with no configured platform returns {:ok, :skipped}" do
      {:ok, n} =
        Notification.build(%{
          @valid_attrs
          | recipient_channels: [%{platform: "mattermost", identifier: "U123", preferred: true}]
        })

      assert {:ok, :skipped} = Notifications.notify(n)
    end

    test "rejects a plain map — only %Notification{} accepted" do
      assert_raise FunctionClauseError, fn ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        apply(Notifications, :notify, [%{subject: "S", body: "B", recipient_channels: []}])
      end
    end
  end
end
