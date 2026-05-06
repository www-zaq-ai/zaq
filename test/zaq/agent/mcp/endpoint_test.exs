defmodule Zaq.Agent.MCP.EndpointTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.MCP.Endpoint

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        name: "MCP Endpoint",
        type: "local",
        status: "enabled",
        timeout_ms: 5000,
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem"],
        headers: %{"X-App" => "zaq"},
        secret_headers: %{"Authorization" => "enc:test"},
        environments: %{"HOME" => "/tmp"},
        secret_environments: %{"TOKEN" => "enc:test"},
        settings: %{"scope" => "project"}
      },
      overrides
    )
  end

  test "changeset is valid for local endpoint with string maps" do
    changeset = Endpoint.changeset(%Endpoint{}, valid_attrs())

    assert changeset.valid?
  end

  test "changeset requires command for local type" do
    changeset = Endpoint.changeset(%Endpoint{}, valid_attrs(%{command: nil}))

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).command
  end

  test "changeset requires url for remote type" do
    attrs = valid_attrs(%{type: "remote", command: nil, url: nil})
    changeset = Endpoint.changeset(%Endpoint{}, attrs)

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).url
  end

  test "changeset does not enforce local/remote required fields for unknown type" do
    attrs = valid_attrs(%{type: "invalid", command: nil, url: nil})
    changeset = Endpoint.changeset(%Endpoint{}, attrs)

    refute changeset.valid?
    refute Map.has_key?(errors_on(changeset), :command)
    refute Map.has_key?(errors_on(changeset), :url)
    assert "is invalid" in errors_on(changeset).type
  end

  test "changeset validates map fields" do
    attrs =
      valid_attrs(%{
        headers: "bad",
        secret_headers: [],
        environments: 1,
        secret_environments: :x,
        settings: nil
      })

    changeset = Endpoint.changeset(%Endpoint{}, attrs)

    refute changeset.valid?

    assert "is invalid" in errors_on(changeset).headers
    assert "is invalid" in errors_on(changeset).secret_headers
    assert "is invalid" in errors_on(changeset).environments
    assert "is invalid" in errors_on(changeset).secret_environments
  end

  test "changeset rejects non-string key/value maps" do
    attrs =
      valid_attrs(%{
        headers: %{123 => "value"},
        secret_headers: %{"Authorization" => 123},
        environments: %{nil => "value"},
        secret_environments: %{"TOKEN" => nil}
      })

    changeset = Endpoint.changeset(%Endpoint{}, attrs)

    refute changeset.valid?
    assert "must contain only string keys and values" in errors_on(changeset).headers
    assert "must contain only string keys and values" in errors_on(changeset).secret_headers
    assert "must contain only string keys and values" in errors_on(changeset).environments
    assert "must contain only string keys and values" in errors_on(changeset).secret_environments
  end
end
