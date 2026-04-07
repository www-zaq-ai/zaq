defmodule ZaqWeb.Components.IconRegistryTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.IconRegistry

  test "renders known icon variants and preserves class" do
    cases = [
      {"section", "ai"},
      {"section", "communication"},
      {"section", "accounts"},
      {"section", "system"},
      {"nav", "dashboard"},
      {"nav", "ai"},
      {"nav", "prompt"},
      {"nav", "ingestion"},
      {"nav", "ontology"},
      {"nav", "knowledge_gap"},
      {"nav", "channels"},
      {"nav", "history"},
      {"nav", "users"},
      {"nav", "people"},
      {"nav", "roles"},
      {"nav", "license"},
      {"nav", "conversations"},
      {"nav", "config"},
      {"provider", "mattermost"}
    ]

    Enum.each(cases, fn {namespace, name} ->
      html =
        render_component(&IconRegistry.icon/1,
          namespace: namespace,
          name: name,
          class: "w-4 h-4 test-icon"
        )

      assert html =~ "<svg"
      assert html =~ "test-icon"
    end)
  end

  test "provider fallback renders default icon for unknown provider" do
    html =
      render_component(&IconRegistry.icon/1,
        namespace: "provider",
        name: "unknown-provider",
        class: "w-5 h-5 provider-fallback"
      )

    assert html =~ "<svg"
    assert html =~ "provider-fallback"
    assert html =~ "<circle cx=\"12\" cy=\"12\" r=\"10\""
  end

  test "global fallback renders default icon for unknown namespace/name" do
    html =
      render_component(&IconRegistry.icon/1,
        namespace: "does-not-exist",
        name: "missing",
        class: "w-5 h-5 global-fallback"
      )

    assert html =~ "<svg"
    assert html =~ "global-fallback"
    assert html =~ "<circle cx=\"12\" cy=\"12\" r=\"10\""
  end
end
