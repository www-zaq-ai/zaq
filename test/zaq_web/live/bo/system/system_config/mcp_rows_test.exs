defmodule ZaqWeb.Live.BO.System.SystemConfig.MCPRowsTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.MCP
  alias Zaq.Types.EncryptedString
  alias ZaqWeb.Live.BO.System.SystemConfig.MCPRows

  test "rows/1 decrypts secret fields for form rows" do
    {:ok, encrypted} = EncryptedString.encrypt("Bearer x")

    endpoint = %MCP.Endpoint{secret_headers: %{"Authorization" => encrypted}}

    rows = MCPRows.rows(endpoint)

    assert rows.secret_headers == [%{"key" => "Authorization", "value" => "Bearer x"}]
  end

  test "rows/1 falls back to blank rows for invalid input and row types" do
    expected = %{
      args: [%{"key" => "", "value" => ""}],
      headers: [%{"key" => "", "value" => ""}],
      secret_headers: [%{"key" => "", "value" => ""}],
      environments: [%{"key" => "", "value" => ""}],
      secret_environments: [%{"key" => "", "value" => ""}],
      settings: "{}"
    }

    assert MCPRows.rows("not_a_map") == expected

    invalid_endpoint = %MCP.Endpoint{
      args: "bad",
      headers: "bad",
      secret_headers: "bad",
      environments: "bad",
      secret_environments: "bad"
    }

    assert MCPRows.rows(invalid_endpoint) == expected
  end

  test "build_endpoint_payload/2 normalizes rows and keeps sorted indices" do
    fallback_rows = MCPRows.rows(%MCP.Endpoint{})

    params = %{
      "type" => "remote",
      "name" => "Remote A",
      "url" => "http://localhost:5000/mcp",
      "headers_rows" => %{
        "2" => %{"key" => "X-Z", "value" => "z"},
        "0" => %{"key" => "X-A", "value" => "a"}
      }
    }

    {rows, parsed} = MCPRows.build_endpoint_payload(params, fallback_rows)

    assert rows.headers == [
             %{"key" => "X-A", "value" => "a"},
             %{"key" => "X-Z", "value" => "z"}
           ]

    assert parsed["headers"] == %{"X-A" => "a", "X-Z" => "z"}
    assert parsed["type"] == "remote"
  end

  test "rows_from_params/2 normalizes fallback rows for non-map params" do
    fallback_rows = %{
      args: [],
      headers: [],
      secret_headers: [],
      environments: [],
      secret_environments: [],
      settings: "{}"
    }

    rows = MCPRows.rows_from_params("bad_params", fallback_rows)

    assert rows.args == [%{"key" => "", "value" => ""}]
    assert rows.headers == [%{"key" => "", "value" => ""}]
    assert rows.secret_headers == [%{"key" => "", "value" => ""}]
    assert rows.environments == [%{"key" => "", "value" => ""}]
    assert rows.secret_environments == [%{"key" => "", "value" => ""}]
    assert rows.settings == "{}"
  end

  test "rows_from_params/2 falls back to default endpoint rows for invalid fallback data" do
    assert MCPRows.rows_from_params(nil, "invalid_fallback") == MCPRows.rows(%MCP.Endpoint{})
  end

  test "parse_endpoint_params/2 applies local scope clearing" do
    params = %{
      "type" => "local",
      "name" => "Local endpoint",
      "command" => "node server.js",
      "url" => "https://remote.example/mcp",
      "status" => "enabled"
    }

    rows = %{
      args: [%{"value" => "--stdio"}],
      headers: [%{"key" => "X-A", "value" => "a"}],
      secret_headers: [%{"key" => "Authorization", "value" => "Bearer y"}],
      environments: [%{"key" => "MCP_ENV", "value" => "dev"}],
      secret_environments: [%{"key" => "TOKEN", "value" => "abc"}],
      settings: "{}"
    }

    parsed = MCPRows.parse_endpoint_params(params, rows)

    assert parsed["command"] == "node server.js"
    assert parsed["url"] == nil
    assert parsed["headers"] == %{}
    assert parsed["secret_headers"] == %{}
  end

  test "parse_endpoint_params/2 applies remote scope clearing" do
    params = %{
      "type" => "remote",
      "name" => "Remote endpoint",
      "command" => "node server.js",
      "url" => "https://remote.example/mcp",
      "status" => "enabled"
    }

    rows = %{
      args: [%{"value" => "--stdio"}],
      headers: [%{"key" => "X-A", "value" => "a"}],
      secret_headers: [%{"key" => "Authorization", "value" => "Bearer y"}],
      environments: [%{"key" => "MCP_ENV", "value" => "dev"}],
      secret_environments: [%{"key" => "TOKEN", "value" => "abc"}],
      settings: "{}"
    }

    parsed = MCPRows.parse_endpoint_params(params, rows)

    assert parsed["url"] == "https://remote.example/mcp"
    assert parsed["command"] == nil
    assert parsed["args"] == []
    assert parsed["environments"] == %{}
    assert parsed["secret_environments"] == %{}
  end

  test "parse_endpoint_params/2 keeps non-binary command values and normalizes settings" do
    params = %{"type" => "custom", "command" => 123}

    rows = %{
      args: [],
      headers: [],
      secret_headers: [],
      environments: [],
      secret_environments: [],
      settings: 42
    }

    parsed = MCPRows.parse_endpoint_params(params, rows)

    assert parsed["settings"] == %{}
    assert parsed["command"] == 123
  end

  test "remove_row/3 always keeps at least one row" do
    rows = %{headers: [%{"key" => "X-A", "value" => "a"}]}

    next_rows = MCPRows.remove_row(rows, "headers", 0)

    assert next_rows.headers == [%{"key" => "", "value" => ""}]
  end

  test "rows_from_params/2 normalizes non-list fallback row values" do
    params = %{"headers_rows" => "bad"}

    rows = MCPRows.rows_from_params(params, %{headers: "oops"})

    assert rows.headers == [%{"key" => "", "value" => ""}]
  end

  test "rows/1 decrypts invalid secret row values as blank strings" do
    endpoint = %MCP.Endpoint{secret_headers: %{"Authorization" => "enc:not-encrypted"}}

    rows = MCPRows.rows(endpoint)

    assert rows.secret_headers == [%{"key" => "Authorization", "value" => ""}]
  end

  test "parse_endpoint_params/2 returns empty map for invalid inputs" do
    assert MCPRows.parse_endpoint_params(nil, %{}) == %{}
    assert MCPRows.parse_endpoint_params(%{}, nil) == %{}
  end
end
