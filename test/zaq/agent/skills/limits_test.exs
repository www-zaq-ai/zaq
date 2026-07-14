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
