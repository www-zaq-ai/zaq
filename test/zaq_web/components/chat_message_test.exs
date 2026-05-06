defmodule ZaqWeb.Components.ChatMessageTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.ChatMessage

  test "user_bubble renders content, timestamp, and actions slot" do
    html =
      render_component(&ChatMessage.user_bubble/1,
        content: "Hello there",
        timestamp: ~N[2026-04-15 09:30:00],
        actions: [%{inner_block: fn _, _ -> "Copy" end}]
      )

    assert html =~ "Hello there"
    assert html =~ "09:30"
    assert html =~ "Copy"
  end

  test "assistant_bubble renders typewriter attrs, source chip and click target" do
    html =
      render_component(&ChatMessage.assistant_bubble/1,
        content: "Answer with source",
        timestamp: ~N[2026-04-15 09:31:00],
        msg_id: "m-1",
        confidence: 0.91,
        sources: [%{"index" => 1, "path" => "docs/guide.md"}],
        source_click_event: "open_source_preview",
        source_click_target: "#preview-modal",
        actions: [%{inner_block: fn _, _ -> "Feedback" end}]
      )

    assert html =~ "id=\"msg-body-m-1\""
    assert html =~ "phx-hook=\"Typewriter\""
    assert html =~ "phx-update=\"ignore\""
    assert html =~ "title=\"91% confidence\""
    assert html =~ "width:91%"
    assert html =~ "background:#22c55e"
    assert html =~ "data-testid=\"source-chip\""
    assert html =~ "phx-click=\"open_source_preview\""
    assert html =~ "phx-value-path=\"docs/guide.md\""
    assert html =~ "phx-target=\"#preview-modal\""
    assert html =~ "[1] guide.md"
    assert html =~ "Feedback"
  end

  test "assistant_bubble renders error style and hides confidence when zero" do
    html =
      render_component(&ChatMessage.assistant_bubble/1,
        content: "Error response",
        timestamp: ~N[2026-04-15 09:32:00],
        confidence: 0.0,
        is_error: true,
        sources: []
      )

    assert html =~ "bg-red-50 border-red-200"
    assert html =~ "text-red-600"
    assert html =~ "Error response"
    refute html =~ "% confidence"
  end

  test "assistant_bubble uses amber and red confidence colors for mid and low values" do
    mid_html =
      render_component(&ChatMessage.assistant_bubble/1,
        content: "Mid confidence",
        timestamp: ~N[2026-04-15 09:33:00],
        confidence: 0.6
      )

    low_html =
      render_component(&ChatMessage.assistant_bubble/1,
        content: "Low confidence",
        timestamp: ~N[2026-04-15 09:34:00],
        confidence: 0.2
      )

    assert mid_html =~ "background:#f59e0b"
    assert low_html =~ "background:#ef4444"
  end

  test "source chips render disabled states and labels for non-previewable and memory sources" do
    html =
      render_component(&ChatMessage.assistant_bubble/1,
        content: "Source variants",
        timestamp: ~N[2026-04-15 09:35:00],
        source_click_event: "open_source_preview",
        sources: [
          %{"path" => "bin/tool.exe"},
          %{"index" => 2, "type" => "memory", "label" => "llm_general-knowledge"}
        ]
      )

    assert html =~ "Preview unavailable"
    assert html =~ "disabled"
    assert html =~ "tool.exe"
    assert html =~ "[2] Internal memory - llm general knowledge"
  end

  test "source chips render navigate links and fallback labels without click event" do
    html =
      render_component(&ChatMessage.assistant_bubble/1,
        content: "Source links",
        timestamp: ~N[2026-04-15 09:36:00],
        sources: [
          "docs/readme.md",
          %{"title" => "Policy Document"},
          %{foo: "bar"}
        ]
      )

    assert html =~ "href=\"/bo/preview/docs/readme.md\""
    assert html =~ "readme.md"
    assert html =~ "Policy Document"
    assert html =~ ">source<"
    assert html =~ "disabled"
  end

  # ── user_bubble with filters (build_body_html) ───────────────────────────────

  test "user_bubble with file filter renders clickable button with phx-click open_preview_modal" do
    filters = [
      %Zaq.Ingestion.ContentSource{
        connector: "documents",
        source_prefix: "documents/hr/policy.md",
        label: "policy.md",
        type: :file
      }
    ]

    html =
      render_component(&ChatMessage.user_bubble/1,
        content: "Check @policy.md for details",
        timestamp: ~N[2026-04-15 09:30:00],
        filters: filters
      )

    assert html =~ ~s(phx-click="open_preview_modal")
    assert html =~ ~s(phx-value-path="documents/hr/policy.md")
    assert html =~ "@policy.md"
    refute html =~ ~s(<span class="underline opacity-80">@policy.md</span>)
  end

  test "user_bubble with folder filter renders underlined span without phx-click" do
    filters = [
      %Zaq.Ingestion.ContentSource{
        connector: "documents",
        source_prefix: "documents/hr",
        label: "hr",
        type: :folder
      }
    ]

    html =
      render_component(&ChatMessage.user_bubble/1,
        content: "Look in @hr folder",
        timestamp: ~N[2026-04-15 09:30:00],
        filters: filters
      )

    assert html =~ ~s(<span class="underline opacity-80">@hr</span>)
    refute html =~ "phx-click"
  end

  test "user_bubble with connector filter renders underlined span without phx-click" do
    filters = [
      %Zaq.Ingestion.ContentSource{
        connector: "sharepoint",
        source_prefix: "sharepoint",
        label: "sharepoint",
        type: :connector
      }
    ]

    html =
      render_component(&ChatMessage.user_bubble/1,
        content: "Search @sharepoint for files",
        timestamp: ~N[2026-04-15 09:30:00],
        filters: filters
      )

    assert html =~ ~s(<span class="underline opacity-80">@sharepoint</span>)
    refute html =~ "phx-click"
  end

  test "user_bubble with filters but no @mention in content renders text normally" do
    filters = [
      %Zaq.Ingestion.ContentSource{
        connector: "documents",
        source_prefix: "documents/hr",
        label: "hr",
        type: :folder
      }
    ]

    html =
      render_component(&ChatMessage.user_bubble/1,
        content: "Plain text with no mention",
        timestamp: ~N[2026-04-15 09:30:00],
        filters: filters
      )

    assert html =~ "Plain text with no mention"
    refute html =~ "phx-click"
    refute html =~ "underline opacity-80"
  end

  test "user_bubble with multiple filters, only one matching mention is highlighted" do
    filters = [
      %Zaq.Ingestion.ContentSource{
        connector: "documents",
        source_prefix: "documents/hr",
        label: "hr",
        type: :folder
      },
      %Zaq.Ingestion.ContentSource{
        connector: "documents",
        source_prefix: "documents/legal/contract.md",
        label: "contract.md",
        type: :file
      }
    ]

    html =
      render_component(&ChatMessage.user_bubble/1,
        content: "Review @hr policies",
        timestamp: ~N[2026-04-15 09:30:00],
        filters: filters
      )

    assert html =~ ~s(<span class="underline opacity-80">@hr</span>)
    refute html =~ "contract.md"
  end

  test "user_bubble with no filters renders content HTML-escaped as-is" do
    html =
      render_component(&ChatMessage.user_bubble/1,
        content: "<script>alert(1)</script>",
        timestamp: ~N[2026-04-15 09:30:00],
        filters: []
      )

    refute html =~ "<script>"
    assert html =~ "&lt;script&gt;"
  end

  test "source chips support atom-key maps, id links, and non-binary memory labels" do
    html =
      render_component(&ChatMessage.assistant_bubble/1,
        content: "More source variants",
        timestamp: ~N[2026-04-15 09:37:00],
        source_click_event: "open_source_preview",
        sources: [
          %{index: 3, path: "docs/atom.md"},
          %{index: 4, type: "memory", label: 123}
        ]
      )

    assert html =~ "[3] atom.md"
    assert html =~ "phx-value-path=\"docs/atom.md\""
    assert html =~ "[4] Internal memory - LLM general knowledge"

    no_click_html =
      render_component(&ChatMessage.assistant_bubble/1,
        content: "No click variants",
        timestamp: ~N[2026-04-15 09:38:00],
        sources: [
          %{"id" => "file-123"},
          %{"path" => "docs/plain.txt"},
          %{"type" => "memory"}
        ]
      )

    assert no_click_html =~ "href=\"/bo/files/file-123\""
    assert no_click_html =~ "href=\"/bo/preview/docs/plain.txt\""
    assert no_click_html =~ "disabled"
  end
end
