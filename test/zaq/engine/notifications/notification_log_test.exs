defmodule Zaq.Engine.Notifications.NotificationLogTest do
  use Zaq.DataCase, async: true

  @moduletag capture_log: true

  alias Zaq.Engine.Notifications.NotificationLog
  alias Zaq.Repo

  @valid_attrs %{
    sender: "system",
    payload: %{"subject" => "Hello", "body" => "World"}
  }

  # ---------------------------------------------------------------------------
  # create_log/1
  # ---------------------------------------------------------------------------

  describe "create_log/1" do
    test "persists all required fields" do
      assert {:ok, log} = NotificationLog.create_log(@valid_attrs)
      assert log.sender == "system"
      assert log.payload == %{"subject" => "Hello", "body" => "World"}
      assert log.status == "pending"
      assert log.channels_tried == []
    end

    test "persists all optional fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          recipient_name: "Alice",
          recipient_ref_type: "user",
          recipient_ref_id: 42
        })

      assert {:ok, log} = NotificationLog.create_log(attrs)
      assert log.recipient_name == "Alice"
      assert log.recipient_ref_type == "user"
      assert log.recipient_ref_id == 42
    end

    test "default status is pending" do
      assert {:ok, %{status: "pending"}} = NotificationLog.create_log(@valid_attrs)
    end

    test "payload JSONB round-trips correctly" do
      payload = %{"subject" => "Test", "body" => "Body text", "html_body" => "<p>Body</p>"}
      assert {:ok, log} = NotificationLog.create_log(%{@valid_attrs | payload: payload})
      reloaded = Repo.get!(NotificationLog, log.id)
      assert reloaded.payload == payload
    end

    test "returns error when sender is missing" do
      assert {:error, changeset} = NotificationLog.create_log(%{payload: %{"s" => "b"}})
      assert "can't be blank" in errors_on(changeset).sender
    end

    test "returns error when payload is missing" do
      assert {:error, changeset} = NotificationLog.create_log(%{sender: "system"})
      assert "can't be blank" in errors_on(changeset).payload
    end
  end

  # ---------------------------------------------------------------------------
  # append_attempt/3
  # ---------------------------------------------------------------------------

  describe "append_attempt/3" do
    test "appends a successful attempt entry" do
      {:ok, log} = NotificationLog.create_log(@valid_attrs)
      :ok = NotificationLog.append_attempt(log.id, "email", :ok)

      reloaded = Repo.get!(NotificationLog, log.id)
      [entry] = reloaded.channels_tried
      assert entry["platform"] == "email"
      assert entry["status"] == "ok"
      assert entry["error"] == nil
      assert entry["attempted_at"] != nil
    end

    test "appends a failed attempt entry with error reason" do
      {:ok, log} = NotificationLog.create_log(@valid_attrs)
      :ok = NotificationLog.append_attempt(log.id, "email", {:error, :smtp_unreachable})

      reloaded = Repo.get!(NotificationLog, log.id)
      [entry] = reloaded.channels_tried
      assert entry["platform"] == "email"
      assert entry["status"] == "error"
      assert entry["error"] =~ "smtp_unreachable"
    end

    test "atomic append — two sequential calls produce two distinct entries" do
      {:ok, log} = NotificationLog.create_log(@valid_attrs)
      :ok = NotificationLog.append_attempt(log.id, "email", :ok)
      :ok = NotificationLog.append_attempt(log.id, "mattermost", {:error, "timeout"})

      reloaded = Repo.get!(NotificationLog, log.id)
      assert length(reloaded.channels_tried) == 2
      platforms = Enum.map(reloaded.channels_tried, & &1["platform"])
      assert "email" in platforms
      assert "mattermost" in platforms
    end

    test "records attempted_at timestamp on each entry" do
      {:ok, log} = NotificationLog.create_log(@valid_attrs)
      :ok = NotificationLog.append_attempt(log.id, "email", :ok)

      reloaded = Repo.get!(NotificationLog, log.id)
      [entry] = reloaded.channels_tried
      assert {:ok, _dt, _} = DateTime.from_iso8601(entry["attempted_at"])
    end
  end

  # ---------------------------------------------------------------------------
  # transition_status/2
  # ---------------------------------------------------------------------------

  describe "transition_status/2" do
    test "allows pending → sent" do
      {:ok, log} = NotificationLog.create_log(@valid_attrs)
      assert {:ok, updated} = NotificationLog.transition_status(log, "sent")
      assert updated.status == "sent"
    end

    test "allows pending → skipped" do
      {:ok, log} = NotificationLog.create_log(@valid_attrs)
      assert {:ok, updated} = NotificationLog.transition_status(log, "skipped")
      assert updated.status == "skipped"
    end

    test "allows pending → failed" do
      {:ok, log} = NotificationLog.create_log(@valid_attrs)
      assert {:ok, updated} = NotificationLog.transition_status(log, "failed")
      assert updated.status == "failed"
    end

    test "rejects failed → sent (invalid transition)" do
      {:ok, log} = NotificationLog.create_log(@valid_attrs)
      {:ok, failed_log} = NotificationLog.transition_status(log, "failed")

      assert {:error, :invalid_transition} =
               NotificationLog.transition_status(failed_log, "sent")
    end

    test "rejects sent → failed (invalid transition)" do
      {:ok, log} = NotificationLog.create_log(@valid_attrs)
      {:ok, sent_log} = NotificationLog.transition_status(log, "sent")

      assert {:error, :invalid_transition} =
               NotificationLog.transition_status(sent_log, "failed")
    end

    test "rejects skipped → sent (invalid transition)" do
      {:ok, log} = NotificationLog.create_log(@valid_attrs)
      {:ok, skipped_log} = NotificationLog.transition_status(log, "skipped")

      assert {:error, :invalid_transition} =
               NotificationLog.transition_status(skipped_log, "sent")
    end
  end
end
