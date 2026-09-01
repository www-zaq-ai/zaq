defmodule Zaq.System.HttpCredentialProviderRefTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.System.HttpCredentialProviderRef

  property "formats positive IDs as dynamic HTTP provider references" do
    check all(id <- integer(1..1_000_000_000)) do
      assert {:ok, reference} = HttpCredentialProviderRef.format(id)
      assert reference == "http:#{id}"
      assert HttpCredentialProviderRef.dynamic_http?(reference)
      assert {:ok, {:http, ^id}} = HttpCredentialProviderRef.parse(reference)
    end
  end

  test "identifies binary HTTP namespace references" do
    for provider <- ["http:42", "http:"] do
      assert HttpCredentialProviderRef.dynamic_http?(provider)
    end

    for provider <- ["google_drive", "HTTP:42"] do
      refute HttpCredentialProviderRef.dynamic_http?(provider)
    end
  end

  test "returns false for non-binary providers" do
    for provider <- [nil, 42, :http, [], %{}] do
      refute HttpCredentialProviderRef.dynamic_http?(provider)
    end
  end

  test "formats and parses canonical dynamic HTTP provider references" do
    assert {:ok, "http:42"} = HttpCredentialProviderRef.format(42)
    assert {:ok, {:http, 42}} = HttpCredentialProviderRef.parse("http:42")
  end

  test "parses existing static providers without interpreting them" do
    assert {:ok, {:static, "google_drive"}} = HttpCredentialProviderRef.parse("google_drive")
  end

  test "rejects malformed dynamic HTTP provider references" do
    for ref <- ["http:", "http:0", "http:-1", "http:abc", "http:12x"] do
      assert {:error, :invalid_http_provider_id} = HttpCredentialProviderRef.parse(ref)
    end
  end

  test "rejects invalid provider references" do
    assert {:error, :invalid_provider_ref} = HttpCredentialProviderRef.parse(12)
    assert {:error, :invalid_provider_ref} = HttpCredentialProviderRef.parse(" ")
  end

  test "rejects non-positive and non-numeric provider IDs" do
    for id <- [0, -1] do
      assert {:error, :invalid_http_provider_id} = HttpCredentialProviderRef.format(id)
    end

    for id <- [nil, :http, [], %{}] do
      assert {:error, :invalid_http_provider_id} =
               HttpCredentialProviderRef.parse_id_for_validator(id)
    end
  end
end
