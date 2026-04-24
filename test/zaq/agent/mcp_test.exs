defmodule Zaq.Agent.MCPTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.MCP
  alias Zaq.Agent.MCP.Endpoint
  alias Zaq.Repo

  setup do
    prev_secret = Application.get_env(:zaq, Zaq.System.SecretConfig, [])

    Application.put_env(:zaq, Zaq.System.SecretConfig,
      encryption_key: Base.encode64(:crypto.strong_rand_bytes(32)),
      key_id: "test-v1"
    )

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.System.SecretConfig, prev_secret)
    end)

    :ok
  end

  describe "create_mcp_endpoint/1" do
    test "creates valid local endpoint" do
      assert {:ok, %Endpoint{} = endpoint} =
               MCP.create_mcp_endpoint(%{
                 name: "Local FS",
                 type: "local",
                 status: "enabled",
                 timeout_ms: 6000,
                 command: "npx",
                 args: ["-y", "@modelcontextprotocol/server-filesystem"],
                 environments: %{"HOME" => "/tmp"},
                 headers: %{},
                 settings: %{"scope" => "project"}
               })

      assert endpoint.type == "local"
      assert endpoint.command == "npx"
      assert endpoint.status == "enabled"
      assert endpoint.timeout_ms == 6000
    end

    test "creates valid remote endpoint" do
      assert {:ok, %Endpoint{} = endpoint} =
               MCP.create_mcp_endpoint(%{
                 name: "Remote Fetch",
                 type: "remote",
                 status: "disabled",
                 timeout_ms: 5000,
                 url: "http://localhost:8000/mcp",
                 headers: %{"X-App" => "zaq"},
                 settings: %{}
               })

      assert endpoint.type == "remote"
      assert endpoint.url == "http://localhost:8000/mcp"
      assert endpoint.status == "disabled"
    end

    test "rejects local endpoint without command" do
      assert {:error, changeset} =
               MCP.create_mcp_endpoint(%{
                 name: "Bad Local",
                 type: "local",
                 status: "enabled",
                 timeout_ms: 5000
               })

      assert "can't be blank" in errors_on(changeset).command
    end

    test "rejects remote endpoint without url" do
      assert {:error, changeset} =
               MCP.create_mcp_endpoint(%{
                 name: "Bad Remote",
                 type: "remote",
                 status: "enabled",
                 timeout_ms: 5000
               })

      assert "can't be blank" in errors_on(changeset).url
    end

    test "rejects invalid timeout" do
      assert {:error, changeset} =
               MCP.create_mcp_endpoint(%{
                 name: "Bad Timeout",
                 type: "remote",
                 status: "enabled",
                 timeout_ms: 0,
                 url: "http://localhost:8000/mcp"
               })

      assert "must be greater than 0" in errors_on(changeset).timeout_ms
    end
  end

  describe "predefined catalog merge and policy" do
    test "filter includes disabled placeholders for predefined MCPs not yet enabled" do
      assert {:ok, _custom} =
               MCP.create_mcp_endpoint(%{
                 name: "Custom One",
                 type: "remote",
                 status: "enabled",
                 timeout_ms: 5000,
                 url: "http://localhost:8080/mcp"
               })

      {entries, total} = MCP.filter_mcp_endpoints(%{}, page: 1, per_page: 100)
      catalog_ids = MCP.predefined_catalog() |> Map.keys() |> MapSet.new()

      entry_predefined_ids =
        entries
        |> Enum.map(& &1.predefined_id)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      assert MapSet.subset?(catalog_ids, entry_predefined_ids)
      assert total >= map_size(MCP.predefined_catalog()) + 1

      assert Enum.any?(entries, fn entry ->
               entry.predefined_id in Map.keys(MCP.predefined_catalog()) and
                 entry.status == "disabled"
             end)
    end

    test "enable_predefined creates endpoint with enabled status" do
      assert {:ok, endpoint} = MCP.enable_predefined("filesystem")
      assert endpoint.predefined_id == "filesystem"
      assert endpoint.status == "enabled"
      assert endpoint.name == MCP.predefined_catalog()["filesystem"].name
    end

    test "predefined endpoint with editable false cannot be updated" do
      assert {:ok, endpoint} = MCP.enable_predefined("filesystem")

      assert {:error, changeset} =
               MCP.update_mcp_endpoint(endpoint, %{
                 name: "Renamed FS",
                 type: endpoint.type,
                 status: endpoint.status,
                 timeout_ms: endpoint.timeout_ms,
                 command: endpoint.command
               })

      assert "predefined MCP is not editable" in errors_on(changeset).base
    end

    test "predefined endpoint with editable true can be updated" do
      assert {:ok, endpoint} = MCP.enable_predefined("fetch")

      assert {:ok, updated} =
               MCP.update_mcp_endpoint(endpoint, %{
                 name: "Fetch Updated",
                 type: endpoint.type,
                 status: "enabled",
                 timeout_ms: 9000,
                 url: "http://localhost:8123/mcp"
               })

      assert updated.name == "Fetch Updated"
      assert updated.timeout_ms == 9000
    end
  end

  describe "secret value encryption" do
    test "stores secret map keys in plaintext and values encrypted" do
      assert {:ok, endpoint} =
               MCP.create_mcp_endpoint(%{
                 name: "Secret Remote",
                 type: "remote",
                 status: "enabled",
                 timeout_ms: 5000,
                 url: "http://localhost:8000/mcp",
                 secret_headers: %{"Authorization" => "Bearer top-secret"},
                 secret_environments: %{"API_TOKEN" => "very-secret"}
               })

      [row] =
        Repo.query!(
          "SELECT secret_headers, secret_environments FROM mcp_endpoints WHERE id = $1",
          [endpoint.id]
        ).rows

      [raw_headers, raw_env] = row

      assert Map.has_key?(raw_headers, "Authorization")
      assert String.starts_with?(raw_headers["Authorization"], "enc:")

      assert Map.has_key?(raw_env, "API_TOKEN")
      assert String.starts_with?(raw_env["API_TOKEN"], "enc:")
    end

    test "blank secret value update preserves existing encrypted value" do
      assert {:ok, endpoint} =
               MCP.create_mcp_endpoint(%{
                 name: "Preserve Secret",
                 type: "remote",
                 status: "enabled",
                 timeout_ms: 5000,
                 url: "http://localhost:8000/mcp",
                 secret_headers: %{"Authorization" => "Bearer first"}
               })

      before = MCP.get_mcp_endpoint!(endpoint.id).secret_headers["Authorization"]

      assert {:ok, updated} =
               MCP.update_mcp_endpoint(endpoint, %{
                 name: endpoint.name,
                 type: endpoint.type,
                 status: endpoint.status,
                 timeout_ms: endpoint.timeout_ms,
                 url: endpoint.url,
                 secret_headers: %{"Authorization" => ""}
               })

      assert updated.secret_headers["Authorization"] == before
    end

    test "returns field-level encryption error when key is invalid" do
      prev_secret = Application.get_env(:zaq, Zaq.System.SecretConfig, [])

      Application.put_env(:zaq, Zaq.System.SecretConfig,
        encryption_key: "invalid",
        key_id: "test-v1"
      )

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.System.SecretConfig, prev_secret)
      end)

      assert {:error, changeset} =
               MCP.create_mcp_endpoint(%{
                 name: "Encrypt Fail",
                 type: "remote",
                 status: "enabled",
                 timeout_ms: 5000,
                 url: "http://localhost:8000/mcp",
                 secret_headers: %{"Authorization" => "bad"}
               })

      assert hd(errors_on(changeset).secret_headers) =~ "could not be encrypted"
    end
  end
end
