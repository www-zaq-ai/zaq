defmodule Zaq.Agent.Skills.LimitsTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Skills.Limits

  defmodule Stub do
    @moduledoc false
    def get(:zaq, :agent_skills, _default, _opts), do: Process.get(:agent_skills_stub)
    def get(app, key, default, _opts), do: Application.get_env(app, key, default)
  end

  defp stub(overrides) do
    Process.put(:agent_skills_stub, overrides)
    Stub
  end

  test "exposes the configured defaults" do
    limits = Limits.all()

    assert limits.skill_body_warning_tokens == 16_000
    assert limits.skill_body_max_tokens == 32_000
    assert limits.skill_body_max_bytes == 131_072
    assert limits.bundle_max_bytes == 50 * 1024 * 1024
    assert limits.bundle_max_files == 500
    assert limits.resource_max_bytes == 5 * 1024 * 1024
    assert limits.resource_max_files == 10
    assert limits.resource_read_max_bytes == 262_144
    assert limits.resource_listing_max_files == 100
  end

  test "the listing cap is comfortably above the upload cap" do
    limits = Limits.all()

    # An operator can upload 10 files per skill, so the manifest cap only ever bites on a
    # bundle that arrived by import (M4) — never on one built through the BO.
    assert limits.resource_listing_max_files > limits.resource_max_files
  end

  test "read caps are overridable independently of the import caps" do
    limits =
      Limits.all(config: stub(%{resource_read_max_bytes: 1024, resource_listing_max_files: 5}))

    assert limits.resource_read_max_bytes == 1024
    assert limits.resource_listing_max_files == 5

    # `bundle_max_*` guard SKILL.md import, not reads — moving a read cap must not move them.
    assert limits.bundle_max_bytes == 50 * 1024 * 1024
    assert limits.bundle_max_files == 500
  end

  test "the resource read cap is well under the upload cap" do
    limits = Limits.all()

    # Uploads may be binaries no model will be handed as text (a PDF reference); the read
    # cap is what protects the context window. Collapsing the two would either block real
    # PDFs or let a multi-megabyte file reach a tool result.
    assert limits.resource_read_max_bytes < limits.resource_max_bytes
  end

  test "resource limits are overridable like the rest" do
    limits = Limits.all(config: stub(%{resource_max_bytes: 1024}))

    assert limits.resource_max_bytes == 1024
    assert limits.resource_read_max_bytes == 262_144
  end

  test "a partial override wins over the default, leaving the rest intact" do
    limits = Limits.all(config: stub(%{skill_body_max_tokens: 5}))

    assert limits.skill_body_max_tokens == 5
    # untouched keys keep their default
    assert limits.skill_body_max_bytes == 131_072
  end

  test "get/2 fetches a single limit" do
    assert Limits.get(:skill_body_max_tokens) == 32_000
    assert Limits.get(:skill_body_max_tokens, config: stub(%{skill_body_max_tokens: 9})) == 9
  end
end
