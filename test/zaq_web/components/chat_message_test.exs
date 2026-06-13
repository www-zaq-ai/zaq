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

  test "assistant_bubble renders markdown immediately, source chip and click target" do
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
    refute html =~ "phx-hook=\"Typewriter\""
    refute html =~ "phx-update=\"ignore\""
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

    atom_no_click_html =
      render_component(&ChatMessage.assistant_bubble/1,
        content: "Atom no-click source",
        timestamp: ~N[2026-04-15 09:39:00],
        sources: [
          %{path: "docs/atom-no-click.md"}
        ]
      )

    assert atom_no_click_html =~ "href=\"/bo/preview/docs/atom-no-click.md\""
  end

  test "message_info_popin renders metadata, measurements, and collapsed traces" do
    html =
      render_component(&ChatMessage.message_info_popin/1,
        visible: true,
        message_id: "msg-1",
        message_info: %{
          agent: %{"name" => "Answering Agent"},
          model: "openai:gpt-4o-mini",
          measurements: %{"latency_ms" => 42},
          traces: [
            %{
              "id" => "trace-1",
              "type" => "tool_call",
              "name" => "search_code",
              "started_at" => "2026-05-02T10:00:00Z",
              "duration_ms" => 42
            }
          ]
        },
        expanded_ids: MapSet.new(),
        close_event: "close_message_info_modal",
        toggle_event: "toggle_trace_details"
      )

    assert html =~ "data-testid=\"message-info-popin\""
    assert html =~ "Answering Agent"
    assert html =~ "openai:gpt-4o-mini"
    assert html =~ "latency_ms"
    assert html =~ "Tool Call · Search Code"
    assert html =~ "data-testid=\"trace-row-trace-1\""
    refute html =~ "data-testid=\"trace-details-trace-1\""
  end

  test "message_info_popin handles non-map message_info" do
    html =
      render_component(&ChatMessage.message_info_popin/1,
        visible: true,
        message_id: "msg-non-map",
        message_info: nil,
        close_event: "close_message_info_modal",
        toggle_event: "toggle_trace_details"
      )

    assert html =~ "Agent"
    assert html =~ "Model"
    assert html =~ "n/a"
    assert html =~ "Traces (0)"
    assert html =~ "No measurements available."
  end

  test "message_info_popin formats empty and string measurement values" do
    html =
      render_component(&ChatMessage.message_info_popin/1,
        visible: true,
        message_id: "msg-measurements",
        message_info: %{
          measurements: %{
            empty: "",
            nil_value: nil,
            string_value: "ready"
          },
          traces: []
        },
        expanded_ids: MapSet.new(),
        close_event: "close_message_info_modal",
        toggle_event: "toggle_trace_details"
      )

    assert html =~ "empty"
    assert html =~ "nil_value"
    assert html =~ "string_value"
    assert html =~ "ready"
    assert html =~ "n/a"
  end

  test "message_info_popin renders fallback trace label and tool_call_id legacy type" do
    html =
      render_component(&ChatMessage.message_info_popin/1,
        visible: true,
        message_id: "msg-legacy-trace",
        message_info: %{
          traces: [
            %{"id" => "fallback-label", "duration_ms" => nil},
            %{id: "legacy-id", tool_call_id: "atom-call", duration_ms: "slow"}
          ]
        },
        expanded_ids: MapSet.new(),
        close_event: "close_message_info_modal",
        toggle_event: "toggle_trace_details"
      )

    assert html =~ "Trace"
    assert html =~ ~s(data-testid="trace-row-fallback-label")
    assert html =~ "Tool Call"
    assert html =~ ~s(data-testid="trace-row-legacy-id")
    assert html =~ "n/a"
  end

  test "message_info_popin sorts traces by numeric timestamps" do
    html =
      render_component(&ChatMessage.message_info_popin/1,
        visible: true,
        message_id: "msg-sorted-traces",
        message_info: %{
          traces: [
            %{"id" => "float-later", "name" => "float_later", "started_at_ms" => 20.9},
            %{"id" => "int-earlier", "name" => "int_earlier", "started_at_ms" => 10}
          ]
        },
        expanded_ids: MapSet.new(),
        close_event: "close_message_info_modal",
        toggle_event: "toggle_trace_details"
      )

    assert html =~ "Int Earlier"
    assert html =~ "Float Later"
    assert String.split(html, ~s(data-testid="trace-row-int-earlier")) |> length() == 2
    assert html =~ ~s(data-testid="trace-row-int-earlier")
    assert html =~ ~s(data-testid="trace-row-float-later")

    assert :binary.match(html, ~s(trace-row-int-earlier)) <
             :binary.match(html, ~s(trace-row-float-later))
  end

  test "message_info_popin expands full json and supports legacy tool call fields" do
    html =
      render_component(&ChatMessage.message_info_popin/1,
        visible: true,
        message_id: "msg-2",
        message_info: %{
          agent: nil,
          model: nil,
          measurements: %{},
          traces: [
            %{
              "tool_call_id" => "call-edge",
              "tool_name" => "fetch.metrics",
              "timestamp" => "",
              "params" => nil,
              "response" => fn -> :ok end,
              "response_time_ms" => 12.345
            }
          ]
        },
        expanded_ids: MapSet.new(["call-edge"]),
        close_event: "close_message_info_modal",
        toggle_event: "toggle_trace_details"
      )

    assert html =~ "data-testid=\"trace-details-call-edge\""
    assert html =~ "Tool Call · Fetch Metrics"
    assert html =~ "12.35 ms"
    assert html =~ "n/a"
    assert html =~ "nil"
    assert html =~ "#Function&lt;"
    assert html =~ "phx-click=\"copy_message\""
  end

  test "message_info_popin handles empty values" do
    html =
      render_component(&ChatMessage.message_info_popin/1,
        visible: true,
        message_id: "msg-3",
        message_info: %{},
        expanded_ids: MapSet.new(),
        close_event: "close_message_info_modal",
        toggle_event: "toggle_trace_details"
      )

    assert html =~ "data-testid=\"message-info-popin\""
    assert html =~ "Traces (0)"
    assert html =~ "No measurements available."
  end

  test "message_info_popin does not render when hidden or message id is not binary" do
    hidden_html =
      render_component(&ChatMessage.message_info_popin/1,
        visible: false,
        message_id: "msg-1",
        message_info: %{},
        close_event: "close_message_info_modal",
        toggle_event: "toggle_trace_details"
      )

    non_binary_id_html =
      render_component(&ChatMessage.message_info_popin/1,
        visible: true,
        message_id: nil,
        message_info: %{},
        close_event: "close_message_info_modal",
        toggle_event: "toggle_trace_details"
      )

    refute hidden_html =~ "data-testid=\"message-info-popin\""
    refute non_binary_id_html =~ "data-testid=\"message-info-popin\""
  end

  # ── Group 1 — assistant_bubble with structured error_type ───────────────────

  describe "assistant_bubble structured error detail block" do
    setup do
      original = Application.get_env(:zaq, :user_portal_base_url)
      Application.put_env(:zaq, :user_portal_base_url, "https://portal.test")
      on_exit(fn -> Application.put_env(:zaq, :user_portal_base_url, original) end)
      :ok
    end

    test "budget_exceeded error renders green top-up box and portal URL" do
      html =
        render_component(&ChatMessage.assistant_bubble/1,
          content: "Budget exceeded\n{\"type\":\"budget_exceeded\"}",
          timestamp: ~N[2026-04-15 09:40:00],
          is_error: true,
          error_type: :budget_exceeded,
          sources: []
        )

      assert html =~ "text-red-600 mb-2"
      assert html =~ "bg-green-50"
      assert html =~ "https://portal.test"
      assert html =~ "Top up wallet"
      refute html =~ "font-mono text-["
    end

    test "generic error with multi-line content renders pre code box and copy button" do
      html =
        render_component(&ChatMessage.assistant_bubble/1,
          content: "Something failed\nStack trace detail here",
          timestamp: ~N[2026-04-15 09:41:00],
          is_error: true,
          sources: []
        )

      assert html =~ "text-red-600 mb-2"
      assert html =~ "font-mono"
      assert html =~ "Stack trace detail here"
      assert html =~ ~s(phx-click="copy_message")
      assert html =~ ~s(phx-value-text="Stack trace detail here")
      refute html =~ "bg-green-50"
    end
  end

  # ── Group 4 — detect_error_type_from_body/1 and portal_base_url/0 ───────────

  describe "assistant_bubble body-driven error type detection" do
    setup do
      original = Application.get_env(:zaq, :user_portal_base_url)
      Application.put_env(:zaq, :user_portal_base_url, "https://portal.test")
      on_exit(fn -> Application.put_env(:zaq, :user_portal_base_url, original) end)
      :ok
    end

    test "detects budget_exceeded from JSON body and renders top-up box" do
      html =
        render_component(&ChatMessage.assistant_bubble/1,
          content: "Budget exceeded\n{\"type\":\"budget_exceeded\"}",
          timestamp: ~N[2026-04-15 09:42:00],
          is_error: true,
          sources: []
        )

      assert html =~ "bg-green-50"
      assert html =~ "https://portal.test"
    end

    test "returns nil for non-budget JSON body and shows code box instead" do
      html =
        render_component(&ChatMessage.assistant_bubble/1,
          content: "Some error\n{\"type\":\"other_error\"}",
          timestamp: ~N[2026-04-15 09:43:00],
          is_error: true,
          sources: []
        )

      assert html =~ "font-mono"
      refute html =~ "bg-green-50"
    end

    test "structured error_type takes precedence over body parsing" do
      html =
        render_component(&ChatMessage.assistant_bubble/1,
          content: "Budget error\nsome plain detail",
          timestamp: ~N[2026-04-15 09:44:00],
          is_error: true,
          error_type: :budget_exceeded,
          sources: []
        )

      assert html =~ "bg-green-50"
      assert html =~ "https://portal.test"
    end
  end
end
