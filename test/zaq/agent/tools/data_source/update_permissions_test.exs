defmodule Zaq.Agent.Tools.DataSource.UpdatePermissionsTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.DataSource.UpdatePermissions
  alias Zaq.Event

  defmodule StubNodeRouter do
    def dispatch(%Event{request: %{provider: "disk", params: params}, opts: opts}) do
      send(self(), {:dispatch, opts[:action], params})

      %{
        Event.new(%{}, :channels)
        | response:
            {:ok,
             %{
               records: [%{"id" => "7", "type" => "person"}],
               stats: %{applied_to: 3}
             }}
      }
    end
  end

  defmodule ErrorNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: {:error, :not_found}}
  end

  defmodule UnexpectedNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: :ok}
  end

  test "dispatches the datasource update_permissions action" do
    assert {:ok, %{records: [%{"id" => "7"}], stats: %{applied_to: 3}}} =
             UpdatePermissions.run(
               %{
                 provider: "disk",
                 file_id: "42",
                 grants: [%{type: "person", target_id: "7", access_rights: ["read"]}]
               },
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_update_permissions,
                     %{
                       "file_id" => "42",
                       "grants" => [%{type: "person", target_id: "7", access_rights: ["read"]}]
                     }}
  end

  test "carries a path and volume when the record is named that way" do
    assert {:ok, _result} =
             UpdatePermissions.run(
               %{provider: "disk", path: "reports", volume: "archives", public: true},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_update_permissions,
                     %{"path" => "reports", "volume" => "archives", "public" => true}}
  end

  test "carries a false public flag rather than dropping it as an empty value" do
    # `false` withdraws access from everyone. Treating it like an unset optional field would
    # turn an unshare into a silent no-op.
    assert {:ok, _result} =
             UpdatePermissions.run(
               %{provider: "disk", file_id: "42", public: false},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_update_permissions,
                     %{"file_id" => "42", "public" => false}}
  end

  test "leaves out what the caller never sent" do
    assert {:ok, _result} =
             UpdatePermissions.run(
               %{provider: "disk", file_id: "42"},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :data_source_update_permissions, params}
    refute Map.has_key?(params, "public")
    refute Map.has_key?(params, "grants")
    refute Map.has_key?(params, "path")
  end

  test "formats a datasource error reason" do
    assert {:error, message} =
             UpdatePermissions.run(%{provider: "disk", file_id: "42"}, %{
               node_router: ErrorNodeRouter
             })

    assert message == "Data source permission update failed: :not_found"
  end

  test "returns an unexpected response error" do
    assert {:error, message} =
             UpdatePermissions.run(%{provider: "disk", file_id: "42"}, %{
               node_router: UnexpectedNodeRouter
             })

    assert message == "Unexpected channel response: :ok"
  end

  describe "schema" do
    test "accepts a grant naming a person" do
      assert {:ok, params} =
               Zoi.parse(UpdatePermissions.schema(), %{
                 provider: "disk",
                 file_id: "42",
                 grants: [%{type: "person", target_id: "7"}]
               })

      assert [%{type: "person", target_id: "7"}] = params.grants
    end

    test "accepts a grant naming a team, with explicit rights" do
      assert {:ok, params} =
               Zoi.parse(UpdatePermissions.schema(), %{
                 provider: "disk",
                 file_id: "42",
                 grants: [%{type: "team", target_id: "3", access_rights: ["read", "write"]}]
               })

      assert [%{type: "team", access_rights: ["read", "write"]}] = params.grants
    end

    test "refuses a grant naming neither a person nor a team" do
      assert {:error, errors} =
               Zoi.parse(UpdatePermissions.schema(), %{
                 provider: "disk",
                 file_id: "42",
                 grants: [%{type: "everyone", target_id: "7"}]
               })

      assert Enum.any?(errors, &(&1.path == [:grants, 0, :type]))
    end

    test "refuses a request naming no record, since it would have nothing to share" do
      assert {:error, errors} =
               Zoi.parse(UpdatePermissions.schema(), %{provider: "disk", public: true})

      assert Enum.any?(errors, &(&1.message == "either file_id or path is required"))
    end

    test "accepts a record named by path instead of id" do
      assert {:ok, %{path: "reports"}} =
               Zoi.parse(UpdatePermissions.schema(), %{
                 provider: "disk",
                 path: "reports",
                 public: true
               })
    end

    test "accepts a public flag on its own, with no named grants" do
      assert {:ok, %{public: false}} =
               Zoi.parse(UpdatePermissions.schema(), %{
                 provider: "disk",
                 file_id: "42",
                 public: false
               })
    end
  end

  test "is registered as an agent tool" do
    assert Zaq.Agent.Tools.Registry.valid_tool_key?("data_source.update_permissions")

    assert {:ok, [UpdatePermissions]} =
             Zaq.Agent.Tools.Registry.resolve_modules(["data_source.update_permissions"])
  end
end
