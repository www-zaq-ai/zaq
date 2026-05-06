defmodule Zaq.Agent.MCPTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.MCP
  alias Zaq.Agent.MCP.Endpoint
  alias Zaq.Repo

  defp predefined_catalog, do: MCP.predefined_catalog()

  defp existing_predefined_id! do
    predefined_catalog()
    |> Map.keys()
    |> List.first()
    |> case do
      nil -> raise "expected at least one predefined MCP in catalog"
      id -> id
    end
  end

  defp editable_predefined_id! do
    predefined_catalog()
    |> Enum.find_value(fn {id, entry} -> if entry.editable, do: id end)
    |> case do
      nil -> raise "expected at least one editable predefined MCP in catalog"
      id -> id
    end
  end

  defp non_editable_predefined_id do
    predefined_catalog()
    |> Enum.find_value(fn {id, entry} -> if entry.editable == false, do: id end)
  end

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
    test "default create_mcp_endpoint/0 returns invalid changeset" do
      assert {:error, changeset} = MCP.create_mcp_endpoint()
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end

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

    test "rejects duplicate endpoint names" do
      assert {:ok, _endpoint} =
               MCP.create_mcp_endpoint(%{
                 name: "Duplicate Name",
                 type: "remote",
                 status: "enabled",
                 timeout_ms: 5000,
                 url: "http://localhost:8000/mcp"
               })

      assert {:error, changeset} =
               MCP.create_mcp_endpoint(%{
                 name: "Duplicate Name",
                 type: "remote",
                 status: "disabled",
                 timeout_ms: 5000,
                 url: "http://localhost:9000/mcp"
               })

      assert "has already been taken" in errors_on(changeset).name
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
      predefined_id = existing_predefined_id!()

      assert {:ok, endpoint} = MCP.enable_predefined(predefined_id)
      assert endpoint.predefined_id == predefined_id
      assert endpoint.status == "enabled"
      assert endpoint.name == MCP.predefined_catalog()[predefined_id].name
    end

    test "predefined endpoint with editable false cannot be updated" do
      case non_editable_predefined_id() do
        nil ->
          assert Enum.all?(MCP.predefined_catalog(), fn {_id, entry} -> entry.editable end)

        predefined_id ->
          assert {:ok, endpoint} = MCP.enable_predefined(predefined_id)

          attrs = %{
            name: "Renamed Non Editable",
            type: endpoint.type,
            status: endpoint.status,
            timeout_ms: endpoint.timeout_ms
          }

          attrs =
            case endpoint.type do
              "local" -> Map.put(attrs, :command, endpoint.command)
              "remote" -> Map.put(attrs, :url, endpoint.url)
            end

          assert {:error, changeset} = MCP.update_mcp_endpoint(endpoint, attrs)
          assert "predefined MCP is not editable" in errors_on(changeset).base
      end
    end

    test "predefined endpoint with editable true can be updated" do
      predefined_id = editable_predefined_id!()
      assert {:ok, endpoint} = MCP.enable_predefined(predefined_id)

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

  describe "query and CRUD helpers" do
    test "filter_mcp_endpoints works with default opts" do
      {entries, total} = MCP.filter_mcp_endpoints(%{})
      assert is_list(entries)
      assert is_integer(total)
    end

    test "list/get/change helpers work for persisted endpoint" do
      assert {:ok, endpoint} =
               MCP.create_mcp_endpoint(%{
                 name: "Lookup Endpoint",
                 type: "remote",
                 status: "enabled",
                 timeout_ms: 5000,
                 url: "http://localhost:8000/mcp"
               })

      listed_ids = MCP.list_mcp_endpoints() |> Enum.map(& &1.id)
      assert endpoint.id in listed_ids

      assert %Endpoint{id: endpoint_id} = MCP.get_mcp_endpoint(endpoint.id)
      assert endpoint_id == endpoint.id

      assert %Endpoint{id: endpoint_id_bang} = MCP.get_mcp_endpoint!(endpoint.id)
      assert endpoint_id_bang == endpoint.id

      changeset = MCP.change_mcp_endpoint(endpoint, %{"name" => "Renamed"})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :name) == "Renamed"
    end

    test "delete_mcp_endpoint removes editable entries" do
      assert {:ok, endpoint} =
               MCP.create_mcp_endpoint(%{
                 name: "Delete Me",
                 type: "remote",
                 status: "enabled",
                 timeout_ms: 5000,
                 url: "http://localhost:8000/mcp"
               })

      assert {:ok, _deleted} = MCP.delete_mcp_endpoint(endpoint)
      assert MCP.get_mcp_endpoint(endpoint.id) == nil
    end

    test "delete_mcp_endpoint blocks non-editable predefined entries" do
      case non_editable_predefined_id() do
        nil ->
          assert Enum.all?(MCP.predefined_catalog(), fn {_id, entry} -> entry.editable end)

        predefined_id ->
          assert {:ok, endpoint} = MCP.enable_predefined(predefined_id)
          assert {:error, changeset} = MCP.delete_mcp_endpoint(endpoint)
          assert "predefined MCP is not editable" in errors_on(changeset).base
      end
    end

    test "delete_mcp_endpoint blocks entries assigned to custom agents" do
      assert {:ok, endpoint} =
               MCP.create_mcp_endpoint(%{
                 name: "In Use Endpoint",
                 type: "remote",
                 status: "enabled",
                 timeout_ms: 5000,
                 url: "http://localhost:8000/mcp"
               })

      credential =
        ai_credential_fixture(%{
          name: "MCP Delete Guard Credential #{System.unique_integer([:positive, :monotonic])}",
          provider: "openai",
          sovereign: false
        })

      {:ok, _agent_a} =
        Agent.create_agent(%{
          name: "Alpha Agent #{System.unique_integer([:positive])}",
          job: "job",
          model: "gpt-4.1-mini",
          credential_id: credential.id,
          strategy: "react",
          enabled_tool_keys: [],
          enabled_mcp_endpoint_ids: [endpoint.id],
          conversation_enabled: true,
          active: true,
          advanced_options: %{}
        })

      {:ok, _agent_b} =
        Agent.create_agent(%{
          name: "Beta Agent #{System.unique_integer([:positive])}",
          job: "job",
          model: "gpt-4.1-mini",
          credential_id: credential.id,
          strategy: "react",
          enabled_tool_keys: [],
          enabled_mcp_endpoint_ids: [endpoint.id],
          conversation_enabled: true,
          active: true,
          advanced_options: %{}
        })

      assert {:error, changeset} = MCP.delete_mcp_endpoint(endpoint)

      [base_error | _] = errors_on(changeset).base
      assert base_error =~ "currently used by custom agents"
      assert base_error =~ "Alpha Agent"
      assert base_error =~ "Beta Agent"
      assert base_error =~ "Remove this MCP endpoint from these agents first"
    end

    test "get_by_predefined_id returns enabled predefined entry" do
      predefined_id = existing_predefined_id!()
      assert {:ok, enabled} = MCP.enable_predefined(predefined_id)
      assert %Endpoint{id: enabled_id} = MCP.get_by_predefined_id(predefined_id)
      assert enabled_id == enabled.id
    end
  end

  describe "filtering and predefined enablement" do
    test "filter_mcp_endpoints filters by name, type and status" do
      assert {:ok, _local} =
               MCP.create_mcp_endpoint(%{
                 name: "Alpha Local",
                 type: "local",
                 status: "enabled",
                 timeout_ms: 5000,
                 command: "npx"
               })

      assert {:ok, _remote} =
               MCP.create_mcp_endpoint(%{
                 name: "Beta Remote",
                 type: "remote",
                 status: "disabled",
                 timeout_ms: 5000,
                 url: "http://localhost:8999/mcp"
               })

      {by_name, _} = MCP.filter_mcp_endpoints(%{"name" => "alpha"}, page: 1, per_page: 50)
      assert Enum.any?(by_name, &(&1.name == "Alpha Local"))
      refute Enum.any?(by_name, &(&1.name == "Beta Remote"))

      {by_type, _} = MCP.filter_mcp_endpoints(%{"type" => "local"}, page: 1, per_page: 50)
      assert Enum.any?(by_type, &(&1.name == "Alpha Local"))
      refute Enum.any?(by_type, &(&1.name == "Beta Remote"))

      {by_status, _} =
        MCP.filter_mcp_endpoints(%{"status" => "disabled"}, page: 1, per_page: 50)

      assert Enum.any?(by_status, &(&1.name == "Beta Remote"))
      refute Enum.any?(by_status, &(&1.name == "Alpha Local"))
    end

    test "filter_mcp_endpoints falls back for unknown type/status filters" do
      {entries, _} =
        MCP.filter_mcp_endpoints(%{"type" => "other", "status" => "other"},
          page: 1,
          per_page: 100
        )

      assert is_list(entries)
      assert length(entries) >= map_size(MCP.predefined_catalog())
    end

    test "enable_predefined updates existing endpoint and errors on unknown id" do
      predefined_id = existing_predefined_id!()

      assert {:ok, first} = MCP.enable_predefined(predefined_id)
      assert {:ok, second} = MCP.enable_predefined(predefined_id)
      assert first.id == second.id

      assert {:error, :unknown_predefined_mcp} = MCP.enable_predefined("unknown")
    end

    test "unknown predefined_id remains editable" do
      assert {:ok, endpoint} =
               MCP.create_mcp_endpoint(%{
                 name: "Unknown Predefined",
                 type: "remote",
                 status: "enabled",
                 timeout_ms: 5000,
                 url: "http://localhost:8001/mcp",
                 predefined_id: "custom-source"
               })

      assert {:ok, updated} =
               MCP.update_mcp_endpoint(endpoint, %{
                 name: "Unknown Predefined Updated",
                 type: "remote",
                 status: "enabled",
                 timeout_ms: 5000,
                 url: "http://localhost:8001/mcp",
                 predefined_id: "custom-source"
               })

      assert updated.name == "Unknown Predefined Updated"
    end
  end

  describe "test_list_tools/2" do
    test "accepts endpoint struct directly" do
      endpoint = %Endpoint{type: "remote", timeout_ms: 1500, url: "http://localhost:8000/mcp"}

      assert {:ok, %{status: :ok, endpoint: :zaq_mcp_test}} =
               MCP.test_list_tools(endpoint,
                 register_fn: fn _ -> :ok end,
                 unregister_fn: fn _ -> :ok end,
                 ensure_client_fn: fn _ -> {:error, :no_client} end,
                 list_tools_fn: fn endpoint_id, _ ->
                   {:ok, %{status: :ok, endpoint: endpoint_id}}
                 end
               )
    end

    test "resolves endpoint by id and delegates to runtime" do
      assert {:ok, endpoint} =
               MCP.create_mcp_endpoint(%{
                 name: "Runtime Delegate",
                 type: "remote",
                 status: "enabled",
                 timeout_ms: 5000,
                 url: "http://localhost:8000/mcp"
               })

      register_fn = fn _ -> :ok end
      unregister_fn = fn _ -> :ok end
      ensure_client_fn = fn _ -> {:error, :no_client} end
      list_tools_fn = fn endpoint_id, _ -> {:ok, %{status: :ok, endpoint: endpoint_id}} end

      assert {:ok, %{status: :ok, endpoint: :zaq_mcp_test}} =
               MCP.test_list_tools(endpoint.id,
                 register_fn: register_fn,
                 unregister_fn: unregister_fn,
                 ensure_client_fn: ensure_client_fn,
                 list_tools_fn: list_tools_fn
               )
    end

    test "returns endpoint_not_found for missing id" do
      assert {:error, :endpoint_not_found} = MCP.test_list_tools(-1)
    end
  end

  describe "secret encryption edge cases" do
    test "drops blank secret values when no existing encrypted value exists" do
      assert {:ok, endpoint} =
               MCP.create_mcp_endpoint(%{
                 name: "Blank Secret Drop",
                 type: "remote",
                 status: "enabled",
                 timeout_ms: 5000,
                 url: "http://localhost:8000/mcp",
                 secret_headers: %{"Authorization" => ""}
               })

      assert endpoint.secret_headers == %{}
    end

    test "returns generic encryption error for non-binary secret values" do
      assert {:error, changeset} =
               MCP.create_mcp_endpoint(%{
                 name: "Bad Secret Value",
                 type: "remote",
                 status: "enabled",
                 timeout_ms: 5000,
                 url: "http://localhost:8000/mcp",
                 secret_headers: %{"Authorization" => 123}
               })

      assert hd(errors_on(changeset).secret_headers) =~ "could not be encrypted"
    end
  end
end
