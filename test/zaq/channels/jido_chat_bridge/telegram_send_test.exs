defmodule Zaq.Channels.JidoChatBridge.TelegramSendTest do
  @moduledoc """
  Debugs the Telegram send path by isolating each layer:

    1. fetch_connection_details resolves url + token correctly
    2. JidoChatBridge.send_reply pattern-matches the connection details
    3. do_send_reply calls the adapter with the right chat_id / token
    4. Router.deliver wires all three together

  All tests use a stub Telegram adapter so no real HTTP calls are made.
  """

  use Zaq.DataCase, async: false

  alias Zaq.Channels.{ChannelConfig, Router}
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Engine.Messages.Outgoing

  # ── Stub adapter — captures the send_message call ─────────────────────

  defmodule StubTelegramAdapter do
    @behaviour Jido.Chat.Adapter

    def send_message(chat_id, text, opts) do
      send(
        Process.whereis(:telegram_send_test_observer) || self(),
        {:send_message, chat_id, text, opts}
      )

      {:ok,
       %Jido.Chat.Response{
         external_message_id: "stub_msg_id",
         channel_type: :telegram,
         status: :sent,
         raw: %{}
       }}
    end

    def transform_incoming(_), do: {:error, :not_implemented}

    def listener_child_specs(_bridge_id, _opts), do: {:ok, []}
  end

  # ── Channel config helpers ─────────────────────────────────────────────

  defp insert_telegram_config(attrs \\ %{}) do
    base = %{
      name: "Telegram Test",
      provider: "telegram",
      kind: "retrieval",
      url: "https://api.telegram.org",
      token: "test-bot-token",
      enabled: true,
      settings: %{}
    }

    {:ok, config} =
      %ChannelConfig{}
      |> ChannelConfig.changeset(Map.merge(base, Map.new(attrs)))
      |> Zaq.Repo.insert()

    config
  end

  defp with_stub_telegram_channel(fun) do
    original = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      telegram: %{
        bridge: JidoChatBridge,
        adapter: StubTelegramAdapter,
        ingress_mode: :polling
      }
    })

    on_exit(fn ->
      if original,
        do: Application.put_env(:zaq, :channels, original),
        else: Application.delete_env(:zaq, :channels)
    end)

    fun.()
  end

  defp outgoing(attrs \\ []) do
    struct(
      Outgoing,
      %{
        channel_id: "366923529",
        thread_id: nil,
        body: "hello from ZAQ",
        provider: :telegram,
        metadata: %{}
      }
      |> Map.merge(Map.new(attrs))
    )
  end

  # ── Tests ──────────────────────────────────────────────────────────────

  describe "fetch_connection_details" do
    test "resolves url and token from channel config" do
      insert_telegram_config(url: "https://api.telegram.org", token: "bot-abc-123")

      # access via Router's private helper by calling deliver and inspecting what
      # the bridge receives
      with_stub_telegram_channel(fn ->
        Process.register(self(), :telegram_send_test_observer)

        outgoing = outgoing()
        Router.deliver(outgoing)

        assert_received {:send_message, "366923529", "hello from ZAQ", opts}
        token = Keyword.get(opts, :token) || (opts[:token] || nil)
        assert token == "bot-abc-123", "Expected token bot-abc-123, got: #{inspect(token)}"
      end)
    end

    test "returns empty map and send_reply fails gracefully when no config exists" do
      with_stub_telegram_channel(fn ->
        result = Router.deliver(outgoing())
        assert {:error, :missing_connection_details} = result
      end)
    end
  end

  describe "JidoChatBridge.send_reply/2" do
    test "delegates to do_send_reply when connection details are present" do
      with_stub_telegram_channel(fn ->
        Process.register(self(), :telegram_send_test_observer)

        result =
          JidoChatBridge.send_reply(outgoing(), %{
            url: "https://api.telegram.org",
            token: "bot-abc-123"
          })

        assert :ok = result
        assert_received {:send_message, "366923529", "hello from ZAQ", _opts}
      end)
    end

    test "returns error when connection details are missing" do
      with_stub_telegram_channel(fn ->
        result = JidoChatBridge.send_reply(outgoing(), %{})
        assert {:error, :missing_connection_details} = result
      end)
    end
  end

  describe "JidoChatBridge.do_send_reply/2" do
    test "calls adapter send_message with correct chat_id and token" do
      with_stub_telegram_channel(fn ->
        Process.register(self(), :telegram_send_test_observer)

        result =
          JidoChatBridge.do_send_reply(outgoing(), %{
            url: "https://api.telegram.org",
            token: "bot-abc-123"
          })

        assert :ok = result
        assert_received {:send_message, chat_id, text, opts}
        assert chat_id == "366923529"
        assert text == "hello from ZAQ"

        # Confirm token reaches the adapter opts
        token_in_opts = Keyword.get(opts, :token) || get_in(opts, [:token])

        assert token_in_opts == "bot-abc-123",
               "Token not in adapter opts. Got opts: #{inspect(opts)}"
      end)
    end

    test "uses channel_id as thread_id when thread_id is nil" do
      with_stub_telegram_channel(fn ->
        Process.register(self(), :telegram_send_test_observer)

        JidoChatBridge.do_send_reply(outgoing(thread_id: nil), %{
          url: "https://api.telegram.org",
          token: "bot-abc-123"
        })

        assert_received {:send_message, "366923529", _text, _opts}
      end)
    end
  end

  describe "Router.deliver/1 full path" do
    test "resolves bridge, fetches config, and delivers via send_reply" do
      insert_telegram_config(token: "bot-abc-123")

      with_stub_telegram_channel(fn ->
        Process.register(self(), :telegram_send_test_observer)

        result = Router.deliver(outgoing())

        assert :ok = result
        assert_received {:send_message, "366923529", "hello from ZAQ", opts}

        token_in_opts = Keyword.get(opts, :token) || get_in(opts, [:token])

        assert token_in_opts == "bot-abc-123",
               "Token not passed through Router path. Got opts: #{inspect(opts)}"
      end)
    end

    test "fails gracefully when no channel config exists for telegram" do
      with_stub_telegram_channel(fn ->
        result = Router.deliver(outgoing())
        assert {:error, :missing_connection_details} = result
      end)
    end
  end
end
