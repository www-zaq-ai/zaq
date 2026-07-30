defmodule Zaq.Agent.Tools.Resources.RegistryTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Resources.Registry

  @expected_keys ~w(agent mcp skill user person ai_provider channel_config incoming_message_routing_rule)
  @required_descriptor_keys [
    :key,
    :module,
    :public?,
    :fields,
    :search_fields,
    :filter_fields,
    :sort_fields,
    :default_sort,
    :max_limit
  ]

  test "all returns the complete allowlisted descriptor list" do
    descriptors = Registry.all()

    assert is_list(descriptors)
    assert Enum.map(descriptors, & &1.key) == @expected_keys

    for descriptor <- descriptors do
      assert Enum.all?(@required_descriptor_keys, &Map.has_key?(descriptor, &1))
      assert is_binary(descriptor.key)
      assert is_atom(descriptor.module)
      assert is_boolean(descriptor.public?)
      assert is_list(descriptor.fields)
      assert is_list(descriptor.search_fields)
      assert is_list(descriptor.filter_fields)
      assert is_list(descriptor.sort_fields)
      assert is_atom(descriptor.default_sort)
      assert is_integer(descriptor.max_limit)
      assert descriptor.max_limit > 0
    end
  end

  test "keys returns resource keys in registry order" do
    assert Registry.keys() == @expected_keys
    assert Registry.keys() == Enum.map(Registry.all(), & &1.key)
  end

  test "get returns the descriptor for a known binary key" do
    assert {:ok, descriptor} = Registry.get("agent")

    assert descriptor.key == "agent"
    assert descriptor.module == Zaq.Agent.ConfiguredAgent
    assert descriptor.public? == true
  end

  test "get returns unknown_resource_type for unknown binary keys" do
    assert {:error, {:unknown_resource_type, "not_registered"}} =
             Registry.get("not_registered")
  end

  test "get returns inspected keys for non-binary input" do
    assert {:error, {:unknown_resource_type, "nil"}} = Registry.get(nil)
    assert {:error, {:unknown_resource_type, ":agent"}} = Registry.get(:agent)
    assert {:error, {:unknown_resource_type, "123"}} = Registry.get(123)
  end
end
