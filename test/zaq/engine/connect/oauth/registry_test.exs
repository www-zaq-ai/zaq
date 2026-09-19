defmodule Zaq.Engine.Connect.OAuth.RegistryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Connect.OAuth.Behaviours.{Codex, Standard}
  alias Zaq.Engine.Connect.OAuth.Registry

  test "lists stable, human-readable behaviour entries" do
    assert [standard, codex] = Registry.entries()
    assert %{id: "standard", title: "Standard OAuth2"} = standard
    assert is_binary(standard.description)
    assert codex.id == "openai_chatgpt_codex"
    assert codex.title == "OpenAI Codex / ChatGPT"
    assert standard.module == Standard
    assert codex.module == Codex
  end

  test "defaults missing profiles to standard and resolves registered profiles" do
    assert {:ok, Standard} = Registry.fetch(nil)
    assert {:ok, Standard} = Registry.fetch("")
    assert {:ok, Standard} = Registry.fetch("standard")
    assert {:ok, Codex} = Registry.fetch("openai_chatgpt_codex")
    assert {:error, :unsupported_oauth_behaviour} = Registry.fetch("unknown")
  end

  property "unregistered identifiers never resolve to implementation modules" do
    check all(
            id <- string(:alphanumeric, min_length: 1),
            id not in ["standard", "openai_chatgpt_codex"]
          ) do
      assert {:error, :unsupported_oauth_behaviour} = Registry.fetch(id)
    end
  end
end
