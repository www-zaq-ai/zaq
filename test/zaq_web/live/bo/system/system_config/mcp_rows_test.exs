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

  test "remove_row/3 always keeps at least one row" do
    rows = %{headers: [%{"key" => "X-A", "value" => "a"}]}

    next_rows = MCPRows.remove_row(rows, "headers", 0)

    assert next_rows.headers == [%{"key" => "", "value" => ""}]
  end

  test "parse_endpoint_params/2 returns empty map for invalid inputs" do
    assert MCPRows.parse_endpoint_params(nil, %{}) == %{}
    assert MCPRows.parse_endpoint_params(%{}, nil) == %{}
  end
end
