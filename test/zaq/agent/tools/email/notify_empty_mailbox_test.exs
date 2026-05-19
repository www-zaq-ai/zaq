defmodule Zaq.Agent.Tools.Email.NotifyEmptyMailboxTest do
  use Zaq.DataCase, async: false

  import Swoosh.TestAssertions

  alias Zaq.Agent.Tools.Email.NotifyEmptyMailbox

  describe "run/2 — happy path" do
    test "returns :skipped status with notified: true when mail delivers" do
      assert {:ok, %{status: :skipped, notified: true}, _logs} =
               NotifyEmptyMailbox.run(%{notify_address: "admin@example.com"}, %{})
    end

    test "emits an info log with the notify address" do
      assert {:ok, _result, logs: logs} =
               NotifyEmptyMailbox.run(%{notify_address: "admin@example.com"}, %{})

      assert [%{level: "info", message: message}] = logs
      assert message =~ "admin@example.com"
    end

    test "sends an email to the notify_address" do
      NotifyEmptyMailbox.run(%{notify_address: "ops@example.com"}, %{})

      assert_email_sent(fn email ->
        assert email.to == [{"", "ops@example.com"}] or
                 Enum.any?(email.to, fn
                   {_, addr} -> addr == "ops@example.com"
                   addr when is_binary(addr) -> addr == "ops@example.com"
                 end)
      end)
    end

    test "email subject mentions mailbox check" do
      NotifyEmptyMailbox.run(%{notify_address: "admin@example.com"}, %{})

      assert_email_sent(fn email ->
        assert email.subject =~ "Mailbox check"
      end)
    end

    test "email body mentions no new emails" do
      NotifyEmptyMailbox.run(%{notify_address: "admin@example.com"}, %{})

      assert_email_sent(fn email ->
        body = email.text_body || ""
        assert body =~ "no unseen messages"
      end)
    end
  end

  describe "callbacks" do
    test "on_success/2 returns {:ok, result}" do
      result = %{status: :skipped, notified: true}
      assert {:ok, ^result} = NotifyEmptyMailbox.on_success(result, %{})
    end

    test "on_failure/2 returns :ok" do
      assert :ok = NotifyEmptyMailbox.on_failure(:some_error, %{})
    end
  end

  describe "run/2 — delivery failure path" do
    setup do
      original = Application.get_env(:zaq, Zaq.Mailer)
      Application.put_env(:zaq, Zaq.Mailer, adapter: Zaq.Agent.Tools.Email.FailingMailerAdapter)
      on_exit(fn -> Application.put_env(:zaq, Zaq.Mailer, original) end)
      :ok
    end

    test "returns notified: false and status: :skipped when delivery fails" do
      assert {:ok, %{status: :skipped, notified: false}, _logs} =
               NotifyEmptyMailbox.run(%{notify_address: "bad@example.com"}, %{})
    end

    test "emits a warn log when delivery fails" do
      assert {:ok, _result, logs: logs} =
               NotifyEmptyMailbox.run(%{notify_address: "bad@example.com"}, %{})

      assert [%{level: "warn", message: message}] = logs
      assert message =~ "failed"
    end
  end
end

defmodule Zaq.Agent.Tools.Email.FailingMailerAdapter do
  @behaviour Swoosh.Adapter

  @impl true
  def deliver(_email, _config), do: {:error, :simulated_failure}

  @impl true
  def deliver_many(emails, config), do: Enum.map(emails, &deliver(&1, config))

  @impl true
  def validate_config(_config), do: :ok
end
