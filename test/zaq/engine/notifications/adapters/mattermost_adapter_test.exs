defmodule Zaq.Engine.Notifications.Adapters.MattermostAdapterTest do
  use Zaq.DataCase, async: false
  use Oban.Testing, repo: Zaq.Repo

  @moduletag capture_log: true

  alias Zaq.Engine.Notifications.Adapters.MattermostAdapter

  # ---------------------------------------------------------------------------
  # Fake Mattermost API — injected via Application config
  # ---------------------------------------------------------------------------

  defmodule FakeAPI do
    def send_message(_channel_id, _message, _thread_id \\ nil) do
      :persistent_term.get(__MODULE__, %{}) |> Map.get(:result, {:ok, %{id: "msg1"}})
    end

    def set_result(result) do
      state = :persistent_term.get(__MODULE__, %{})
      :persistent_term.put(__MODULE__, Map.put(state, :result, result))
    end
  end

  # ---------------------------------------------------------------------------
  # Fake Oban worker for on_reply dispatch testing
  # ---------------------------------------------------------------------------

  defmodule FakeWorker do
    use Oban.Worker, queue: :default

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    Application.put_env(:zaq, :mattermost_api_module, FakeAPI)
    FakeAPI.set_result({:ok, %{id: "msg1"}})
    on_exit(fn -> Application.delete_env(:zaq, :mattermost_api_module) end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "platform/0" do
    test "returns \"mattermost\"" do
      assert MattermostAdapter.platform() == "mattermost"
    end
  end

  describe "send/3" do
    test "successful post returns :ok" do
      assert :ok = MattermostAdapter.send("channel-id", %{"subject" => "Q", "body" => "B"}, %{})
    end

    test "API failure returns {:error, reason}" do
      FakeAPI.set_result({:error, :timeout})

      assert {:error, :timeout} =
               MattermostAdapter.send("channel-id", %{"subject" => "Q", "body" => "B"}, %{})
    end

    test "on_reply with valid module dispatches Oban job after successful post" do
      metadata = %{
        "on_reply" => %{
          "module" => to_string(FakeWorker),
          "args" => %{"question_id" => 99}
        }
      }

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert :ok =
                 MattermostAdapter.send(
                   "channel-id",
                   %{"subject" => "Q", "body" => "B"},
                   metadata
                 )

        assert_enqueued(worker: FakeWorker, args: %{"question_id" => 99})
      end)
    end

    test "on_reply with unknown module logs warning and still returns :ok" do
      metadata = %{
        "on_reply" => %{
          "module" => "Elixir.DoesNotExist.Worker",
          "args" => %{}
        }
      }

      assert :ok =
               MattermostAdapter.send("channel-id", %{"subject" => "Q", "body" => "B"}, metadata)
    end

    test "API failure does not dispatch on_reply" do
      FakeAPI.set_result({:error, :timeout})

      metadata = %{
        "on_reply" => %{"module" => to_string(FakeWorker), "args" => %{}}
      }

      assert {:error, :timeout} =
               MattermostAdapter.send("channel-id", %{"subject" => "Q", "body" => "B"}, metadata)

      refute_enqueued(worker: FakeWorker)
    end
  end
end
