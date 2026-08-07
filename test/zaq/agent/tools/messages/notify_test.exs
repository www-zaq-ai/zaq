defmodule Zaq.Agent.Tools.Messages.NotifyTest do
  use Zaq.DataCase, async: true

  alias Jido.Action.Runtime
  alias Jido.Action.Schema
  alias Zaq.Agent.Tools.Messages.Notify
  alias Zaq.Engine.Api
  alias Zaq.Engine.Notifications.Notification

  defmodule OkRouter do
    def dispatch(event) do
      send(self(), {:dispatched, event})

      %{
        event
        | response:
            {:ok,
             %{
               status: :sent,
               channel: "email:smtp",
               channel_identifier: "lead@example.com",
               notification_log_id: 42,
               message_id: "<abc@zaq>",
               thread_id: "<root@zaq>",
               thread_metadata: %{"references" => ["<root@zaq>"]}
             }}
      }
    end
  end

  defmodule SkippedRouter do
    def dispatch(event),
      do: %{event | response: {:ok, %{status: :skipped, notification_log_id: 7}}}
  end

  defmodule FailedRouter do
    def dispatch(event),
      do: %{
        event
        | response:
            {:error, %{status: :failed, notification_log_id: 9, reason: :all_channels_failed}}
      }
  end

  defmodule ErrorRouter do
    def dispatch(event), do: %{event | response: {:error, "channels unavailable"}}
  end

  defmodule StructuredErrorRouter do
    def dispatch(event), do: %{event | response: {:error, {:provider_failed, :timeout}}}
  end

  defmodule UnexpectedRouter do
    def dispatch(event), do: %{event | response: {:ok, :queued}}
  end

  # Routes through the real engine boundary, with only the notification center
  # itself stubbed — the action → Event → Api → Notification.build seam is real.
  defmodule RoutedNodeRouter do
    defmodule FakeNotifications do
      def notify(%Notification{} = notification) do
        send(self(), {:notified, notification})
        {:ok, %{status: :sent, channel: "mattermost", channel_identifier: "town-square"}}
      end
    end

    def dispatch(event) do
      Api.handle_event(
        %{event | opts: event.opts ++ [notifications_module: FakeNotifications]},
        :notify,
        nil
      )
    end
  end

  @ctx %{node_router: OkRouter}

  describe "Jido schemas" do
    test "params and output schemas are valid Zoi schemas" do
      assert Schema.schema_type(Notify.schema()) == :zoi
      assert Schema.schema_type(Notify.output_schema()) == :zoi
      assert :ok = Schema.validate_config_schema(Notify.schema())
      assert :ok = Schema.validate_config_schema(Notify.output_schema())
    end

    test "runtime validation accepts a string payload" do
      assert {:ok, params} =
               Runtime.validate_params(
                 %{channel: "mattermost", destination: "@jad", payload: "Deploy finished"},
                 Notify
               )

      assert params.payload == "Deploy finished"
    end

    test "runtime validation accepts an object payload with string keys" do
      assert {:ok, params} =
               Runtime.validate_params(
                 %{
                   "channel" => "email",
                   "destination" => "lead@example.com",
                   "payload" => %{"subject" => "Welcome", "body" => "Hello there"}
                 },
                 Notify
               )

      assert params.channel == "email"
      assert params.payload.subject == "Welcome"
      assert params.payload.body == "Hello there"
    end

    test "runtime validation rejects an object payload without a body" do
      assert {:error, _} =
               Runtime.validate_params(
                 %{channel: "email", destination: "lead@example.com", payload: %{subject: "Hi"}},
                 Notify
               )
    end

    test "tool schema exposes both payload shapes" do
      tool = Notify.to_tool()

      assert %{properties: properties} = tool.parameters_schema
      assert Map.has_key?(properties, :channel)
      assert Map.has_key?(properties, :destination)
      assert Map.has_key?(properties, :payload)
    end
  end

  describe "run/2 with a string payload" do
    test "dispatches one recipient channel and derives the subject from the body" do
      assert {:ok,
              %{
                notified: true,
                status: "sent",
                channel: "email:smtp",
                destination: "lead@example.com",
                subject: "Deploy finished",
                body: "Deploy finished\nAll green.",
                notification_log_id: 42,
                message_id: "<abc@zaq>",
                thread_id: "<root@zaq>",
                thread_metadata: %{"references" => ["<root@zaq>"]}
              }} =
               Notify.run(
                 %{
                   channel: "email",
                   destination: "lead@example.com",
                   payload: "Deploy finished\nAll green."
                 },
                 @ctx
               )

      assert_received {:dispatched, event}
      assert event.next_hop.destination == :engine
      assert event.opts[:action] == :notify

      assert event.request == %{
               recipient_channels: [%{platform: "email", identifier: "lead@example.com"}],
               subject: "Deploy finished",
               body: "Deploy finished\nAll green.",
               html_body: nil,
               metadata: %{}
             }
    end

    test "truncates a long derived subject and keeps the body intact" do
      body = String.duplicate("a", 200)

      assert {:ok, %{subject: subject, body: ^body}} =
               Notify.run(%{channel: "mattermost", destination: "@jad", payload: body}, @ctx)

      assert String.length(subject) == 120
    end

    test "falls back to a generic subject when the body starts blank" do
      assert {:ok, %{subject: "Notification"}} =
               Notify.run(
                 %{channel: "mattermost", destination: "@jad", payload: "   \nreal content"},
                 @ctx
               )
    end
  end

  describe "run/2 with an object payload" do
    test "forwards subject, html_body, and metadata to the notification center" do
      assert {:ok, %{notified: true, subject: "Welcome", body: "Hello there"}} =
               Notify.run(
                 %{
                   channel: "email",
                   destination: "lead@example.com",
                   payload: %{
                     subject: "Welcome",
                     body: "Hello there",
                     html_body: "<p>Hello there</p>",
                     metadata: %{"topic" => "onboarding"}
                   }
                 },
                 @ctx
               )

      assert_received {:dispatched, event}
      assert event.request.subject == "Welcome"
      assert event.request.html_body == "<p>Hello there</p>"
      assert event.request.metadata == %{"topic" => "onboarding"}
    end

    test "consumes a string-keyed payload after a JSONB round-trip" do
      assert {:ok, %{subject: "Welcome"}} =
               Notify.run(
                 %{
                   "channel" => "email",
                   "destination" => "lead@example.com",
                   "payload" => %{"subject" => "Welcome", "body" => "Hello there"}
                 },
                 @ctx
               )
    end

    test "derives the subject when the object omits or blanks it" do
      assert {:ok, %{subject: "Hello there"}} =
               Notify.run(
                 %{
                   channel: "email",
                   destination: "lead@example.com",
                   payload: %{body: "Hello there"}
                 },
                 @ctx
               )

      assert {:ok, %{subject: "Notification"}} =
               Notify.run(
                 %{
                   channel: "email",
                   destination: "lead@example.com",
                   payload: %{subject: "  ", body: "  \nHello"}
                 },
                 @ctx
               )
    end
  end

  describe "run/2 failures" do
    test "rejects a missing channel or destination without dispatching" do
      assert {:error, "channel is required"} =
               Notify.run(%{channel: "  ", destination: "@jad", payload: "hi"}, @ctx)

      assert {:error, "destination is required"} =
               Notify.run(%{channel: "mattermost", destination: nil, payload: "hi"}, @ctx)

      refute_received {:dispatched, _event}
    end

    test "rejects payloads without a usable body" do
      assert {:error, "payload body is required"} =
               Notify.run(
                 %{channel: "mattermost", destination: "@jad", payload: %{body: "  "}},
                 @ctx
               )

      assert {:error, "payload body is required"} =
               Notify.run(%{channel: "mattermost", destination: "@jad", payload: ""}, @ctx)

      assert {:error, "payload must be a string or an object"} =
               Notify.run(%{channel: "mattermost", destination: "@jad", payload: 42}, @ctx)

      refute_received {:dispatched, _event}
    end

    test "rejects non-map params" do
      assert {:error, "params must be a map"} = Notify.run(:nope, @ctx)
    end

    test "reports a skipped delivery as a successful no-op" do
      assert {:ok, %{notified: false, status: "skipped", notification_log_id: 7}} =
               Notify.run(
                 %{channel: "mattermost", destination: "@jad", payload: "hi"},
                 %{node_router: SkippedRouter}
               )
    end

    test "surfaces an exhausted delivery as an error" do
      assert {:error, "notify_failed::all_channels_failed"} =
               Notify.run(
                 %{channel: "mattermost", destination: "@jad", payload: "hi"},
                 %{node_router: FailedRouter}
               )
    end

    test "returns engine errors verbatim and tags unexpected shapes" do
      assert {:error, "channels unavailable"} =
               Notify.run(
                 %{channel: "mattermost", destination: "@jad", payload: "hi"},
                 %{node_router: ErrorRouter}
               )

      assert {:error, "{:provider_failed, :timeout}"} =
               Notify.run(
                 %{channel: "mattermost", destination: "@jad", payload: "hi"},
                 %{node_router: StructuredErrorRouter}
               )

      assert {:error, "notify_failed:{:ok, :queued}"} =
               Notify.run(
                 %{channel: "mattermost", destination: "@jad", payload: "hi"},
                 %{node_router: UnexpectedRouter}
               )
    end

    test "defaults to the real NodeRouter when the context carries none" do
      # No channel config is enabled in the test env, so the notification center
      # skips delivery — proving the default router reached the engine for real.
      assert {:ok, %{notified: false, status: "skipped", notification_log_id: log_id}} =
               Notify.run(%{channel: "mattermost", destination: "@jad", payload: "hi"}, %{})

      assert is_integer(log_id)
    end
  end

  describe "engine seam" do
    test "the engine builds a validated Notification from the action request" do
      assert {:ok, %{notified: true, channel: "mattermost", destination: "town-square"}} =
               Notify.run(
                 %{
                   channel: "mattermost",
                   destination: "town-square",
                   payload: %{subject: "Standup", body: "Starting now"}
                 },
                 %{node_router: RoutedNodeRouter}
               )

      assert_received {:notified, %Notification{} = notification}

      assert notification.recipient_channels == [
               %{platform: "mattermost", identifier: "town-square"}
             ]

      assert notification.subject == "Standup"
      assert notification.body == "Starting now"
      assert notification.sender == "system"
    end

    test "the engine rejects a request the notification center would refuse" do
      event =
        Zaq.Event.new(
          %{
            recipient_channels: [%{platform: "email", identifier: "a@b.c"}],
            subject: "",
            body: ""
          },
          :engine,
          opts: [action: :notify]
        )

      assert %{response: {:error, "subject is required and must be a non-blank string"}} =
               Api.handle_event(event, :notify, nil)
    end

    test "the engine rejects a request without recipient channels" do
      event = Zaq.Event.new(%{subject: "Hi", body: "There"}, :engine, opts: [action: :notify])

      assert %{response: {:error, {:invalid_request, %{subject: "Hi"}}}} =
               Api.handle_event(event, :notify, nil)
    end
  end
end
