defmodule Zaq.HttpRequest.HostMatcherTest do
  use ExUnit.Case, async: true

  alias Zaq.HttpRequest.HostMatcher

  test "matches exact hosts" do
    assert HostMatcher.matches?("api.example.com", "api.example.com")
    refute HostMatcher.matches?("v1.api.example.com", "api.example.com")
  end

  test "matches domain suffix patterns only for subdomains" do
    assert HostMatcher.matches?("api.example.com", ".example.com")
    assert HostMatcher.matches?("v1.api.example.com", ".example.com")
    refute HostMatcher.matches?("example.com", ".example.com")
    refute HostMatcher.matches?("badexample.com", ".example.com")
  end
end
