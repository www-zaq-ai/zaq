defmodule Zaq.ResourcePolicies.ResourceRefTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.ResourcePolicies.ResourceRef
  alias Zaq.Storage.StorageEntry

  test "uses canonical ACL coordinates, never tool aliases or arbitrary modules" do
    assert ResourceRef.new({"person", 12}) == {:ok, {"person", "12"}}
    assert ResourceRef.new(%Zaq.Agent.ConfiguredAgent{id: 3}) == {:ok, {"configured_agent", "3"}}

    assert ResourceRef.new(%Zaq.System.AIProviderCredential{id: 4}) ==
             {:ok, {"ai_provider_credential", "4"}}

    assert ResourceRef.new(%Zaq.Permissions.ResourcePermission{id: 5}) ==
             {:error, :invalid_resource}

    assert ResourceRef.new({"agent", 3}) == {:error, :invalid_resource}
    assert ResourceRef.new({"person", nil}) == {:error, :invalid_resource}
    assert ResourceRef.new({"person", " 12"}) == {:error, :invalid_resource}
    assert ResourceRef.new({"person", 0}) == {:error, :invalid_resource}

    assert ResourceRef.new(%{resource_type: "person", resource_id: "12"}) ==
             {:error, :invalid_resource}
  end

  test "built-in identities are explicit and restricted to their registered types" do
    assert ResourceRef.default_agent() == {"configured_agent", "default"}
    assert ResourceRef.default_provider() == {"ai_provider_credential", "default"}
    assert ResourceRef.new(ResourceRef.default_agent()) == {:ok, ResourceRef.default_agent()}
    assert ResourceRef.new({"person", "default"}) == {:error, :invalid_resource}
  end

  test "source references reuse storage permission identities, not a policy-only encoding" do
    id = "00000000-0000-4000-8000-000000000042"
    ref = {"storage_entry", id}
    assert ResourceRef.new(%StorageEntry{id: id}) == {:ok, ref}
    assert ResourceRef.new(ref) == {:ok, ref}
    assert ResourceRef.target_schema(ref) == {:error, :unresolved_source}

    for invalid <- [
          nil,
          42,
          "42",
          "volume/file.txt",
          "",
          "not-a-uuid",
          "AAAAAAAA-0000-4000-8000-000000000042",
          <<0::128>>
        ] do
      assert ResourceRef.new({"storage_entry", invalid}) == {:error, :invalid_resource}
    end

    for type <- ["source_file", "source_folder"] do
      assert ResourceRef.new({type, id}) == {:error, :invalid_resource}
    end
  end

  test "policy administration scopes are not resource-policy targets" do
    for id <- [
          "global",
          "v1:" <> Base.url_encode64(Jason.encode!(["person", "12"]), padding: false)
        ] do
      assert ResourceRef.new({"resource_policy_scope", id}) == {:error, :invalid_resource}
    end
  end

  property "source identities preserve the existing UUID without accepting ingestion aliases" do
    check all(bytes <- binary(length: 16), document_id <- integer(1..9_223_372_036_854_775_807)) do
      id = Ecto.UUID.load!(bytes)
      ref = {"storage_entry", id}
      assert ResourceRef.new(ref) == {:ok, ref}
      assert ResourceRef.new(%StorageEntry{id: id}) == {:ok, ref}
      assert ResourceRef.new({"document", document_id}) == {:error, :unresolved_source}
    end
  end
end
