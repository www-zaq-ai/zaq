defmodule ZaqWeb.Components.ToolStepsTest do
  use Zaq.DataCase, async: true
  import Phoenix.LiveViewTest
  alias Zaq.Contracts.ToolStep
  alias ZaqWeb.Components.ChatMessage

  test "status colors are semantic and only running status gently pulses with motion safety" do
    for {state, token} <- [
          {"succeeded", "--zaq-text-color-body-success"},
          {"failed", "--zaq-text-color-body-danger"},
          {"unknown", "--zaq-text-color-body-tertiary"},
          {"running", "--zaq-text-color-body-tertiary"}
        ] do
      steps = ToolStep.project([%{"invocation_id" => "a", "sequence" => 1, "outcome" => state}])

      html =
        render_component(&ChatMessage.assistant_bubble/1,
          content: "",
          timestamp: ~U[2026-10-20 10:00:00Z],
          tool_steps: steps
        )

      status =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-tool-state] > span:nth-child(3)")

      assert LazyHTML.text(status) == state
      assert Enum.join(LazyHTML.attribute(status, "style")) =~ "color: var(#{token})"

      assert Enum.join(LazyHTML.attribute(status, "class")) =~ "motion-safe:animate-pulse" ==
               (state == "running")

      if state == "running" do
        assert Enum.join(LazyHTML.attribute(status, "style")) =~ "animation-duration: 3s"

        assert Enum.join(LazyHTML.attribute(status, "style")) =~
                 "animation-timing-function: ease-in-out"
      end
    end
  end

  test "tool activity reserves available width independently of answer text" do
    steps =
      ToolStep.project([
        %{"invocation_id" => "a", "name" => "search", "sequence" => 1, "outcome" => "running"}
      ])

    for content <- ["", "Answer"] do
      html =
        render_component(&ChatMessage.assistant_bubble/1,
          content: content,
          timestamp: ~U[2026-10-20 10:00:00Z],
          tool_steps: steps
        )

      dom = LazyHTML.from_fragment(html)
      bubble = LazyHTML.query(dom, "[data-testid='chat-assistant-bubble']")
      column = LazyHTML.query(dom, "[data-testid='chat-assistant-bubble'] > div > div")

      assert "w-full" in (bubble |> LazyHTML.attribute("class") |> hd() |> String.split())
      classes = column |> LazyHTML.attribute("class") |> hd() |> String.split()
      assert "w-full" in classes
      assert "max-w-[82%]" in classes
    end
  end

  test "assistant activity renders ordered invocation identities, outcomes and duration" do
    steps =
      ToolStep.project([
        %{"invocation_id" => "b", "name" => "search", "sequence" => 2, "outcome" => "unknown"},
        %{
          "invocation_id" => "a",
          "name" => "search",
          "sequence" => 1,
          "outcome" => "failed",
          "duration_ms" => 7,
          "arguments" => "secret-payload"
        }
      ])

    html =
      render_component(&ChatMessage.assistant_bubble/1,
        content: "Answer",
        timestamp: ~U[2026-10-20 10:00:00Z],
        tool_steps: steps
      )

    assert html =~ "aria-label=\"Tool activity\""
    assert html =~ "data-tool-state=\"failed\""
    assert html =~ "data-tool-state=\"unknown\""
    assert html =~ "7 ms"
    assert {a, _} = :binary.match(html, "data-tool-step-id=\"a\"")
    assert {b, _} = :binary.match(html, "data-tool-step-id=\"b\"")
    assert {answer, _} = :binary.match(html, "Answer")
    assert a < b
    assert b < answer
    refute html =~ "secret-payload"
  end

  test "running activity has an observed timer and no completed answer" do
    [step] =
      ToolStep.project([
        %{
          "invocation_id" => "running",
          "name" => "search",
          "sequence" => 1,
          "outcome" => "running"
        }
      ])

    html =
      render_component(&ChatMessage.assistant_bubble/1,
        content: "",
        timestamp: ~U[2026-10-20 10:00:00Z],
        tool_steps: [step],
        tool_steps_id: "answer-1"
      )

    assert html =~ "id=\"answer-1-tool-1\""
    assert html =~ "phx-hook=\"ToolStepTimer\""
    assert html =~ "~0 s"
    assert html =~ "Approximate elapsed time"
    refute html =~ "The available evidence"
  end

  test "terminal activity displays recorded seconds inline, and unknown has no fabricated duration" do
    steps =
      ToolStep.project([
        %{
          "invocation_id" => "done",
          "sequence" => 1,
          "outcome" => "succeeded",
          "duration_ms" => 1200
        },
        %{"invocation_id" => "unknown", "sequence" => 2, "outcome" => "unknown"}
      ])

    html =
      render_component(&ChatMessage.assistant_bubble/1,
        content: "Final answer",
        timestamp: ~U[2026-10-20 10:00:00Z],
        tool_steps: steps
      )

    assert html =~ "1.2 s"
    refute html =~ "~0 s"
    assert length(Regex.scan(~r/data-tool-duration/, html)) == 1
  end
end
