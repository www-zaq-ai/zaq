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

    assert Registry.registered?(nil) === true
    assert Registry.registered?("") === true
    assert Registry.registered?("standard") === true
    assert Registry.registered?("openai_chatgpt_codex") === true
  end

  test "rejects non-string profiles, including implementation modules" do
    inputs = [
      :standard,
      :openai_chatgpt_codex,
      false,
      true,
      Standard,
      Codex,
      0,
      -1,
      1.5,
      [],
      ~c"standard",
      %{},
      %{"id" => "standard"},
      {:ok, Standard},
      <<1::size(1)>>
    ]

    Enum.each(inputs, fn input ->
      assert Registry.fetch(input) === {:error, :unsupported_oauth_behaviour},
             "expected #{inspect(input)} to be rejected"

      assert Registry.registered?(input) === false,
             "expected #{inspect(input)} to be unregistered"
    end)
  end

  property "unregistered identifiers never resolve to implementation modules" do
    check all(
            id <- string(:alphanumeric, min_length: 1),
            id not in ["standard", "openai_chatgpt_codex"]
          ) do
      assert {:error, :unsupported_oauth_behaviour} = Registry.fetch(id)
    end
  end

  property "non-string, non-nil profiles never resolve" do
    check all(
            profile <-
              one_of([
                member_of([:standard, :openai_chatgpt_codex, Standard, Codex, true, false]),
                integer(-1000..1000),
                float(min: -1000.0, max: 1000.0),
                list_of(integer(0..255), max_length: 16),
                optional_map(%{
                  invalid_profile: integer(-10..10),
                  another_invalid_profile: integer(-10..10)
                }),
                tuple({integer(-10..10), boolean()})
              ])
          ) do
      assert Registry.fetch(profile) === {:error, :unsupported_oauth_behaviour},
             "expected #{inspect(profile)} to be rejected"

      assert Registry.registered?(profile) === false,
             "expected #{inspect(profile)} to be unregistered"
    end
  end
end
