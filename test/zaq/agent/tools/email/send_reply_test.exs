defmodule Zaq.Agent.Tools.Email.SendReplyTest do
  use Zaq.DataCase, async: false

  import Swoosh.TestAssertions

  alias Zaq.Agent.Tools.Email.SendReply

  defp draft(overrides \\ %{}) do
    Map.merge(
      %{
        to_address: "alice@example.com",
        to_name: "Alice Smith",
        subject: "Re: Hello",
        draft: "Hi Alice, thanks for reaching out.",
        message_id: "<orig-msg@mail>"
      },
      overrides
    )
  end

  describe "run/2 — empty drafts list" do
    test "returns zero sent, zero failed, empty results" do
      assert {:ok, %{sent: 0, failed: 0, results: []}, _logs} = SendReply.run(%{drafts: []}, %{})
    end

    test "emits an info log with sent: 0 and failed: 0" do
      assert {:ok, _result, logs: logs} = SendReply.run(%{drafts: []}, %{})
      assert [%{level: "info", metadata: %{sent: 0, failed: 0}}] = logs
    end
  end

  describe "run/2 — single draft delivery" do
    test "returns sent: 1, failed: 0 on success" do
      assert {:ok, %{sent: 1, failed: 0, results: [result]}, _logs} =
               SendReply.run(%{drafts: [draft()]}, %{})

      assert result.to == "alice@example.com"
      assert result.status == :sent
    end

    test "emits an info log with sent: 1 and failed: 0" do
      assert {:ok, _result, logs: logs} = SendReply.run(%{drafts: [draft()]}, %{})
      assert [%{level: "info", metadata: %{sent: 1, failed: 0}}] = logs
    end

    test "sends email with the correct subject" do
      SendReply.run(%{drafts: [draft(%{subject: "Re: My Topic"})]}, %{})
      assert_email_sent(fn email -> assert email.subject == "Re: My Topic" end)
    end

    test "sends email to the correct address" do
      SendReply.run(%{drafts: [draft(%{to_address: "bob@example.com"})]}, %{})

      assert_email_sent(fn email ->
        assert Enum.any?(email.to, fn
                 {_, addr} -> addr == "bob@example.com"
                 addr when is_binary(addr) -> addr == "bob@example.com"
               end)
      end)
    end

    test "uses to_name in the recipient tuple when present" do
      SendReply.run(
        %{drafts: [draft(%{to_name: "Bob Jones", to_address: "bob@example.com"})]},
        %{}
      )

      assert_email_sent(fn email ->
        assert Enum.any?(email.to, fn
                 {"Bob Jones", "bob@example.com"} -> true
                 _ -> false
               end)
      end)
    end

    test "uses raw email string as recipient when to_name is nil" do
      SendReply.run(%{drafts: [draft(%{to_name: nil, to_address: "noname@example.com"})]}, %{})

      assert_email_sent(fn email ->
        assert Enum.any?(email.to, fn
                 {_, "noname@example.com"} -> true
                 "noname@example.com" -> true
                 _ -> false
               end)
      end)
    end

    test "adds In-Reply-To threading header when message_id is present" do
      SendReply.run(%{drafts: [draft(%{message_id: "<thread-id@mail>"})]}, %{})

      assert_email_sent(fn email ->
        headers = email.headers || %{}
        assert headers["In-Reply-To"] == "<thread-id@mail>"
        assert headers["References"] == "<thread-id@mail>"
      end)
    end

    test "sends no threading headers when message_id is nil" do
      SendReply.run(%{drafts: [draft(%{message_id: nil})]}, %{})

      assert_email_sent(fn email ->
        headers = email.headers || %{}
        not Map.has_key?(headers, "In-Reply-To") and not Map.has_key?(headers, "References")
      end)
    end
  end

  describe "run/2 — multiple drafts" do
    test "sends all drafts and tallies correctly" do
      drafts = [
        draft(%{to_address: "a@example.com", to_name: "A"}),
        draft(%{to_address: "b@example.com", to_name: "B"}),
        draft(%{to_address: "c@example.com", to_name: "C"})
      ]

      assert {:ok, %{sent: 3, failed: 0, results: results}, _logs} =
               SendReply.run(%{drafts: drafts}, %{})

      assert length(results) == 3
      assert Enum.all?(results, &(&1.status == :sent))
    end

    test "results contain all recipient addresses" do
      drafts = [
        draft(%{to_address: "x@example.com"}),
        draft(%{to_address: "y@example.com"})
      ]

      {:ok, %{results: results}, _logs} = SendReply.run(%{drafts: drafts}, %{})
      addresses = Enum.map(results, & &1.to)
      assert "x@example.com" in addresses
      assert "y@example.com" in addresses
    end
  end

  describe "run/2 — result shape" do
    test "result map has :to and :status keys" do
      {:ok, %{results: [result]}, _logs} = SendReply.run(%{drafts: [draft()]}, %{})
      assert Map.has_key?(result, :to)
      assert Map.has_key?(result, :status)
    end
  end

  describe "run/2 — delivery failure path" do
    setup do
      original = Application.get_env(:zaq, Zaq.Mailer)

      Application.put_env(:zaq, Zaq.Mailer,
        adapter: Zaq.Agent.Tools.Email.SendReplyFailingAdapter
      )

      on_exit(fn -> Application.put_env(:zaq, Zaq.Mailer, original) end)
      :ok
    end

    test "counts failed draft when SMTP delivery fails" do
      assert {:ok, %{sent: 0, failed: 1, results: [result]}, _logs} =
               SendReply.run(%{drafts: [draft()]}, %{})

      assert result.status == :failed
      assert result.to == "alice@example.com"
    end

    test "emits a warn log when delivery fails" do
      assert {:ok, _result, logs: logs} = SendReply.run(%{drafts: [draft()]}, %{})
      assert [%{level: "warn", metadata: %{sent: 0, failed: 1}}] = logs
    end

    test "result includes :reason key on failure" do
      {:ok, %{results: [result]}, _logs} = SendReply.run(%{drafts: [draft()]}, %{})
      assert Map.has_key?(result, :reason)
    end

    test "mixed success/failure tally is correct with two drafts" do
      Application.put_env(:zaq, Zaq.Mailer,
        adapter: Zaq.Agent.Tools.Email.SendReplyFailingAdapter
      )

      drafts = [draft(%{to_address: "a@x.com"}), draft(%{to_address: "b@x.com"})]

      assert {:ok, %{sent: 0, failed: 2, results: results}, _logs} =
               SendReply.run(%{drafts: drafts}, %{})

      assert Enum.all?(results, &(&1.status == :failed))
    end
  end
end

defmodule Zaq.Agent.Tools.Email.SendReplyFailingAdapter do
  @behaviour Swoosh.Adapter

  @impl true
  def deliver(_email, _config), do: {:error, :smtp_timeout}

  @impl true
  def deliver_many(emails, config), do: Enum.map(emails, &deliver(&1, config))

  @impl true
  def validate_config(_config), do: :ok
end
