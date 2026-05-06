defmodule Zaq.Agent.HistoryTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias Zaq.Agent.History

  describe "format_messages/1" do
    test "returns empty string for empty list" do
      assert History.format_messages([]) == ""
    end

    test "extracts text from string-role user message" do
      messages = [%{role: "user", content: "What is Elixir?"}]
      assert History.format_messages(messages) == "What is Elixir?"
    end

    test "extracts text from atom-role user message" do
      messages = [%{role: :user, content: "What is Elixir?"}]
      assert History.format_messages(messages) == "What is Elixir?"
    end

    test "joins multiple user messages with newline" do
      messages = [
        %{role: "user", content: "Hello"},
        %{role: "user", content: "World"}
      ]

      assert History.format_messages(messages) == "Hello\nWorld"
    end

    test "skips non-user messages" do
      messages = [
        %{role: "user", content: "question"},
        %{role: "assistant", content: "answer"}
      ]

      assert History.format_messages(messages) == "question"
    end

    test "handles plain binary messages" do
      assert History.format_messages(["plain string"]) == "plain string"
    end

    test "handles list-typed content (content_to_string list branch)" do
      messages = [%{role: "user", content: [%{text: "What is"}, %{text: "Elixir?"}]}]
      assert History.format_messages(messages) == "What is Elixir?"
    end

    test "ignores non-text parts in list content" do
      messages = [%{role: "user", content: [%{text: "Hello"}, %{other_key: "ignored"}]}]
      assert History.format_messages(messages) == "Hello"
    end

    test "handles unknown content type gracefully" do
      messages = [%{role: "user", content: 42}]
      assert History.format_messages(messages) == ""
    end

    test "trims leading and trailing whitespace from result" do
      messages = [%{role: "user", content: "  padded  "}]
      assert History.format_messages(messages) == "padded"
    end
  end

  describe "build/1" do
    test "returns empty list for empty list input" do
      assert History.build([]) == []
    end

    test "converts user message to Context.user" do
      history = %{"2026-01-01T00:00:00Z_1_user" => %{"body" => "Hello", "type" => "user"}}
      [msg] = History.build(history)
      assert msg == Context.user("Hello")
    end

    test "converts bot message to Context.assistant" do
      history = %{"2026-01-01T00:00:00Z_2_bot" => %{"body" => "Hi there", "type" => "bot"}}
      [msg] = History.build(history)
      assert msg == Context.assistant("Hi there")
    end

    test "sorts messages chronologically" do
      history = %{
        "2026-01-01T00:00:00Z_2_bot" => %{"body" => "answer", "type" => "bot"},
        "2026-01-01T00:00:00Z_1_user" => %{"body" => "question", "type" => "user"}
      }

      [first, second] = History.build(history)
      assert first == Context.user("question")
      assert second == Context.assistant("answer")
    end
  end
end
