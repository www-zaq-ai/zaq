defmodule Zaq.Agent.Tools.RegistryTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Registry

  test "tools returns expected file tool descriptors" do
    keys = Registry.tools() |> Enum.map(& &1.key)

    assert keys == [
             "files.read_file",
             "files.write_file",
             "files.copy_file",
             "files.move_file",
             "files.delete_file",
             "files.make_directory",
             "files.list_directory"
           ]
  end

  test "valid_tool_key? validates known and unknown keys" do
    assert Registry.valid_tool_key?("files.read_file")
    refute Registry.valid_tool_key?("files.unknown")
    refute Registry.valid_tool_key?(nil)
  end

  test "resolve_modules returns mapped modules in key order" do
    assert {:ok, modules} =
             Registry.resolve_modules([
               "files.write_file",
               "files.read_file",
               "files.read_file"
             ])

    assert modules == [Jido.Tools.Files.WriteFile, Jido.Tools.Files.ReadFile]
  end

  test "resolve_modules returns unknown tool keys" do
    assert {:error, {:unknown_tools, ["files.unknown", "other.missing"]}} =
             Registry.resolve_modules(["files.unknown", "files.read_file", "other.missing"])
  end

  test "model_supports_tools? treats unknown or missing values as false" do
    refute Registry.model_supports_tools?(nil, "gpt-4.1-mini")
    refute Registry.model_supports_tools?("openai", nil)
    refute Registry.model_supports_tools?("custom", "gpt-4.1-mini")
    refute Registry.model_supports_tools?("not_a_provider", "not_a_model")
  end
end
