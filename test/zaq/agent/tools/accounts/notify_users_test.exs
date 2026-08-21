defmodule Zaq.Agent.Tools.Accounts.NotifyUsersTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Schema
  alias Zaq.Agent.Tools.Accounts.NotifyUsers

  defmodule OkRouter do
    def dispatch(event) do
      send(self(), {:dispatched, event})

      %{
        event
        | response:
            {:ok,
             %{
               requested_count: 2,
               recipient_count: 2,
               sent_count: 1,
               skipped_count: 1,
               failed_count: 0,
               results: []
             }}
      }
    end
  end

  defmodule ErrorRouter do
    def dispatch(event), do: %{event | response: {:error, {:boom, :timeout}}}
  end

  defmodule UnexpectedRouter do
    def dispatch(event), do: %{event | response: :queued}
  end

  describe "schema/0" do
    test "has valid Zoi input and output schemas" do
      assert Schema.schema_type(NotifyUsers.schema()) == :zoi
      assert Schema.schema_type(NotifyUsers.output_schema()) == :zoi
      assert :ok = Schema.validate_config_schema(NotifyUsers.schema())
      assert :ok = Schema.validate_config_schema(NotifyUsers.output_schema())
      assert is_map(Schema.to_json_schema(NotifyUsers.schema()))
      assert is_map(Schema.to_json_schema(NotifyUsers.output_schema()))
    end

    test "documents resources.query filtering for BO user selection" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(NotifyUsers)

      assert moduledoc =~ "resources.query"
      assert moduledoc =~ "resource_type: \"user\""
      assert moduledoc =~ "role_id"
      assert moduledoc =~ "must_change_password"
      assert moduledoc =~ "portal_consent"
      assert moduledoc =~ "skip_permissions"
    end
  end

  describe "validate_input/2" do
    test "accepts QueryResources-style maps with extra fields and string keys" do
      assert :ok =
               NotifyUsers.validate_input(%{
                 users: [%{"id" => 1, "username" => "ops", "email" => "ops@example.com"}],
                 subject: "Hello",
                 message: "Body"
               })
    end

    test "rejects empty users, blank text, and invalid ids" do
      assert {:error, "users must include at least one BO user"} =
               NotifyUsers.validate_input(%{users: [], subject: "Hello", message: "Body"})

      assert {:error, "subject must not be blank"} =
               NotifyUsers.validate_input(%{users: [%{id: 1}], subject: " ", message: "Body"})

      assert {:error, "message must not be blank"} =
               NotifyUsers.validate_input(%{users: [%{id: 1}], subject: "Hello", message: ""})

      assert {:error, "each user must include a positive integer id"} =
               NotifyUsers.validate_input(%{
                 users: [%{id: "1"}],
                 subject: "Hello",
                 message: "Body"
               })
    end
  end

  describe "run/2" do
    test "dispatches notify_users to Engine using only user ids" do
      assert {:ok, %{recipient_count: 2, sent_count: 1, skipped_count: 1}} =
               NotifyUsers.run(
                 %{
                   users: [
                     %{"id" => 1, "email" => "untrusted@example.com"},
                     %{id: 2, username: "admin"}
                   ],
                   subject: "Hello",
                   message: "Body"
                 },
                 %{node_router: OkRouter}
               )

      assert_received {:dispatched, event}
      assert event.next_hop.destination == :engine
      assert event.opts[:action] == :notify_users
      assert event.request == %{user_ids: [1, 2], subject: "Hello", message: "Body"}
    end

    test "formats Engine errors for action callers" do
      assert {:error, "{:boom, :timeout}"} =
               NotifyUsers.run(%{users: [%{id: 1}], subject: "Hello", message: "Body"}, %{
                 node_router: ErrorRouter
               })
    end

    test "returns tagged error on unexpected Engine responses" do
      assert {:error, "notify_users_failed::queued"} =
               NotifyUsers.run(%{users: [%{id: 1}], subject: "Hello", message: "Body"}, %{
                 node_router: UnexpectedRouter
               })
    end
  end
end
