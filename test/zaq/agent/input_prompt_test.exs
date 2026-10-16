defmodule Zaq.Agent.InputPromptTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Agent.InputPrompt

  describe "render_message/2" do
    test "separates author, original provider time and unchanged body" do
      message = %{
        author: %{name: "Alice Martin", person_id: 42},
        timestamp: %{value: ~U[2026-01-02 03:04:05Z], source: :provider},
        content: "Please check the invoice."
      }

      assert InputPrompt.render_message(message) ==
               "Author: \"Alice Martin\" [person:42]\nSent at: 2026-01-02 03:04:05Z\nMessage:\nPlease check the invoice."
    end

    test "labels insertion time as recorded time and omits missing time" do
      message = %{
        author: %{name: "Unknown author", person_id: nil},
        timestamp: %{value: ~U[2026-01-02 03:04:05Z], source: :recorded},
        content: "Body"
      }

      assert InputPrompt.render_message(message) ==
               "Author: \"Unknown author\"\nRecorded at: 2026-01-02 03:04:05Z\nMessage:\nBody"

      assert InputPrompt.render_message(%{message | timestamp: nil}) ==
               "Author: \"Unknown author\"\nMessage:\nBody"
    end

    property "quoted names cannot add header lines and the body is preserved verbatim" do
      check all(name <- string(:utf8), body <- string(:utf8)) do
        rendered =
          InputPrompt.render_message(%{author: %{name: name, person_id: nil}, content: body})

        [header, remaining] = String.split(rendered, "\n", parts: 2)
        assert "Author: " <> encoded_name = header
        assert Jason.decode!(encoded_name) == name
        assert remaining == "Message:\n" <> body
      end
    end

    test "preserves native tool and system payloads and non-text input" do
      assert InputPrompt.render_message(%{role: :tool, content: "{\"ok\":true}"}) ==
               "{\"ok\":true}"

      assert InputPrompt.render_message(%{role: :system, content: "Instructions"}) ==
               "Instructions"

      assert InputPrompt.render_message(%{content: {:raw_question, "unchanged"}}) ==
               {:raw_question, "unchanged"}
    end

    test "attachment-only messages use the existing safe metadata projection" do
      rendered =
        InputPrompt.render_message(%{
          content: "",
          attachments: [%{"name" => "photo.png", "content" => "private bytes"}]
        })

      assert rendered ==
               "Author: \"Unknown author\"\nMessage:\n\nAttachments:\n[{\"name\":\"photo.png\"}]"

      refute rendered =~ "private bytes"
    end
  end

  describe "append_attachments/3" do
    test "preserves the prompt when every nonempty-list entry is invalid" do
      assert InputPrompt.append_attachments("Keep this request", [nil, 42, "not a record"], nil) ==
               "Keep this request"
    end

    test "ignores invalid entries while formatting valid attachment metadata" do
      assert InputPrompt.append_attachments(
               "Keep this request",
               [%{"name" => "photo.png"}, nil],
               nil
             ) == "Keep this request\nAttachments:\n[{\"name\":\"photo.png\"}]"
    end
  end
end
