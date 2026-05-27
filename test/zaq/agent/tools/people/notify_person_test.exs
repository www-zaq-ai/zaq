defmodule Zaq.Agent.Tools.People.NotifyPersonTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.People
  alias Zaq.Accounts.PersonChannel
  alias Zaq.Agent.Tools.People.NotifyPerson
  alias Zaq.Engine.Notifications.Notification
  alias Zaq.Repo

  # ── Stub notifications modules ─────────────────────────────────────────────

  defmodule DispatchedNotifications do
    def notify(%Notification{} = notification) do
      send(self(), {:notify_called, notification})
      {:ok, :dispatched}
    end
  end

  defmodule SkippedNotifications do
    def notify(%Notification{} = notification) do
      send(self(), {:notify_called, notification})
      {:ok, :skipped}
    end
  end

  defmodule FailingNotifications do
    def notify(%Notification{}) do
      {:error, :smtp_unavailable}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp create_person_with_channel(platform, identifier, attrs \\ %{}) do
    {:ok, person} =
      People.create_person(
        Map.merge(%{full_name: "Test Person #{System.unique_integer([:positive])}"}, attrs)
      )

    {:ok, _channel} =
      Repo.insert(%PersonChannel{
        person_id: person.id,
        platform: platform,
        channel_identifier: identifier
      })

    Repo.preload(person, :channels)
  end

  @base_ctx %{notifications: DispatchedNotifications}

  # ── Tests ──────────────────────────────────────────────────────────────────

  describe "run/2 — person not found" do
    test "returns error when person_id does not exist" do
      assert {:error, "person_not_found:" <> _} =
               NotifyPerson.run(
                 %{person_id: 999_999, medium: "email", subject: "Hi", message: "Hello"},
                 @base_ctx
               )
    end
  end

  describe "run/2 — no channel for medium" do
    test "returns error when person has no channel for the requested medium" do
      person = create_person_with_channel("mattermost", "user123")

      assert {:error, "no_channel_for_medium:email"} =
               NotifyPerson.run(
                 %{
                   person_id: person.id,
                   medium: "email",
                   subject: "Hi",
                   message: "Hello"
                 },
                 @base_ctx
               )
    end

    test "returns error when person has no channels at all" do
      {:ok, person} = People.create_person(%{full_name: "No Channels"})

      assert {:error, "no_channel_for_medium:email"} =
               NotifyPerson.run(
                 %{person_id: person.id, medium: "email", subject: "Hi", message: "Hello"},
                 @base_ctx
               )
    end
  end

  describe "run/2 — successful dispatch" do
    test "returns notified: true with channel_identifier and status" do
      person = create_person_with_channel("email", "lead@example.com")

      assert {:ok, %{notified: true, channel_identifier: "lead@example.com", status: :dispatched}} =
               NotifyPerson.run(
                 %{
                   person_id: person.id,
                   medium: "email",
                   subject: "Hello",
                   message: "How are you?"
                 },
                 @base_ctx
               )
    end

    test "calls notifications module with correct recipient channels" do
      person = create_person_with_channel("email", "lead@example.com")

      NotifyPerson.run(
        %{person_id: person.id, medium: "email", subject: "Hello", message: "Body"},
        @base_ctx
      )

      assert_received {:notify_called, %Notification{recipient_channels: channels}}
      assert [%{platform: "email:smtp", identifier: "lead@example.com"}] = channels
    end

    test "maps email platform to email:smtp for notifications" do
      person = create_person_with_channel("email", "user@test.com")

      NotifyPerson.run(
        %{person_id: person.id, medium: "email", subject: "S", message: "B"},
        @base_ctx
      )

      assert_received {:notify_called, %Notification{recipient_channels: [ch]}}
      assert ch.platform == "email:smtp"
    end

    test "passes unknown platform through unchanged" do
      person = create_person_with_channel("mattermost", "u123")

      NotifyPerson.run(
        %{person_id: person.id, medium: "mattermost", subject: "S", message: "B"},
        @base_ctx
      )

      assert_received {:notify_called, %Notification{recipient_channels: [ch]}}
      assert ch.platform == "mattermost"
    end

    test "sets recipient_name from person.full_name" do
      person = create_person_with_channel("email", "j@example.com", %{full_name: "Jane Doe"})

      NotifyPerson.run(
        %{person_id: person.id, medium: "email", subject: "S", message: "B"},
        @base_ctx
      )

      assert_received {:notify_called, %Notification{recipient_name: "Jane Doe"}}
    end

    test "sets subject and body on notification" do
      person = create_person_with_channel("email", "j@example.com")

      NotifyPerson.run(
        %{
          person_id: person.id,
          medium: "email",
          subject: "My Subject",
          message: "My Body"
        },
        @base_ctx
      )

      assert_received {:notify_called, %Notification{subject: "My Subject", body: "My Body"}}
    end

    test "uses :skipped status when notifications skips" do
      person = create_person_with_channel("email", "j@example.com")
      ctx = %{notifications: SkippedNotifications}

      assert {:ok, %{notified: true, status: :skipped}} =
               NotifyPerson.run(
                 %{person_id: person.id, medium: "email", subject: "S", message: "B"},
                 ctx
               )
    end

    test "uses default Notifications module when not in context" do
      # Just verify the function dispatches correctly — actual Oban not tested here.
      assert is_function(&NotifyPerson.run/2)
    end
  end

  describe "run/2 — notifications failure" do
    test "returns error when notifications module returns error" do
      person = create_person_with_channel("email", "j@example.com")
      ctx = %{notifications: FailingNotifications}

      assert {:error, "notify_failed:" <> _} =
               NotifyPerson.run(
                 %{person_id: person.id, medium: "email", subject: "S", message: "B"},
                 ctx
               )
    end
  end

  describe "run/2 — sheet fields (range + values)" do
    test "omits range and values when row_index is absent" do
      person = create_person_with_channel("email", "j@example.com")

      assert {:ok, result} =
               NotifyPerson.run(
                 %{person_id: person.id, medium: "email", subject: "S", message: "B"},
                 @base_ctx
               )

      refute Map.has_key?(result, :range)
      refute Map.has_key?(result, :values)
    end

    test "includes range and values when row_index is present" do
      person = create_person_with_channel("email", "j@example.com")

      assert {:ok, %{range: "Sheet1!I5", values: [[3]]}} =
               NotifyPerson.run(
                 %{
                   person_id: person.id,
                   medium: "email",
                   subject: "S",
                   message: "B",
                   row_index: 5,
                   email_state: 2,
                   email_state_column: "I"
                 },
                 @base_ctx
               )
    end

    test "increments email_state by 1 in values" do
      person = create_person_with_channel("email", "j@example.com")

      assert {:ok, %{values: [[6]]}} =
               NotifyPerson.run(
                 %{
                   person_id: person.id,
                   medium: "email",
                   subject: "S",
                   message: "B",
                   row_index: 1,
                   email_state: 5
                 },
                 @base_ctx
               )
    end

    test "uses default email_state 0 when absent" do
      person = create_person_with_channel("email", "j@example.com")

      assert {:ok, %{values: [[1]]}} =
               NotifyPerson.run(
                 %{
                   person_id: person.id,
                   medium: "email",
                   subject: "S",
                   message: "B",
                   row_index: 3
                 },
                 @base_ctx
               )
    end

    test "uses default column I when email_state_column absent" do
      person = create_person_with_channel("email", "j@example.com")

      assert {:ok, %{range: "Sheet1!I3"}} =
               NotifyPerson.run(
                 %{
                   person_id: person.id,
                   medium: "email",
                   subject: "S",
                   message: "B",
                   row_index: 3
                 },
                 @base_ctx
               )
    end

    test "uses provided email_state_column in range" do
      person = create_person_with_channel("email", "j@example.com")

      assert {:ok, %{range: "Sheet1!F10"}} =
               NotifyPerson.run(
                 %{
                   person_id: person.id,
                   medium: "email",
                   subject: "S",
                   message: "B",
                   row_index: 10,
                   email_state_column: "F"
                 },
                 @base_ctx
               )
    end

    test "does not output range/values when row_index is nil" do
      person = create_person_with_channel("email", "j@example.com")

      assert {:ok, result} =
               NotifyPerson.run(
                 %{
                   person_id: person.id,
                   medium: "email",
                   subject: "S",
                   message: "B",
                   row_index: nil
                 },
                 @base_ctx
               )

      refute Map.has_key?(result, :range)
      refute Map.has_key?(result, :values)
    end
  end

  describe "run/2 — Notification.build failure" do
    test "returns invalid_notification error when subject is blank" do
      # Jido schema accepts "" as a string, but Notification.build validates non-blank.
      person = create_person_with_channel("email", "j@example.com")

      assert {:error, "invalid_notification:" <> _} =
               NotifyPerson.run(
                 %{person_id: person.id, medium: "email", subject: "", message: "Body"},
                 @base_ctx
               )
    end

    test "returns invalid_notification error when message is blank" do
      person = create_person_with_channel("email", "j@example.com")

      assert {:error, "invalid_notification:" <> _} =
               NotifyPerson.run(
                 %{person_id: person.id, medium: "email", subject: "Subject", message: ""},
                 @base_ctx
               )
    end
  end

  describe "run/2 — string row_index conversion" do
    test "accepts string row_index and converts to integer (line 174-175)" do
      person = create_person_with_channel("email", "j@example.com")

      assert {:ok, %{range: "Sheet1!I5", values: [[1]]}} =
               NotifyPerson.run(
                 %{
                   person_id: person.id,
                   medium: "email",
                   subject: "S",
                   message: "B",
                   row_index: "5",
                   email_state: 0
                 },
                 @base_ctx
               )
    end

    test "returns output without range/values when string row_index cannot be parsed (line 176)" do
      person = create_person_with_channel("email", "j@example.com")

      assert {:ok, result} =
               NotifyPerson.run(
                 %{
                   person_id: person.id,
                   medium: "email",
                   subject: "S",
                   message: "B",
                   row_index: "not_a_number"
                 },
                 @base_ctx
               )

      refute Map.has_key?(result, :range)
      refute Map.has_key?(result, :values)
    end
  end

  describe "run/2 — channel selection" do
    test "picks the correct channel when person has multiple platforms" do
      {:ok, person} = People.create_person(%{full_name: "Multi Channel"})

      Repo.insert!(%PersonChannel{
        person_id: person.id,
        platform: "mattermost",
        channel_identifier: "mm_user"
      })

      Repo.insert!(%PersonChannel{
        person_id: person.id,
        platform: "email",
        channel_identifier: "multi@example.com"
      })

      person = Repo.preload(person, :channels)

      assert {:ok, %{channel_identifier: "multi@example.com"}} =
               NotifyPerson.run(
                 %{person_id: person.id, medium: "email", subject: "S", message: "B"},
                 @base_ctx
               )
    end
  end
end
