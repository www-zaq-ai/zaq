defmodule Zaq.Agent.Tools.General.DecodeJson do
  @moduledoc """
  Workflow action and ReAct tool: parses a JSON string into a value.

  Pure — no I/O, no context keys. The counterpart is
  `Zaq.Agent.Tools.General.EncodeJson`.

  Decoding is deliberately lenient about the two things that trip up
  real-world input:

  - **Surrounding whitespace is ignored**, which Jason already handles.
  - **A wrapping Markdown code fence is stripped**, so the ```` ```json ... ```
    ```` block an LLM or a documentation page hands over parses as-is. The
    fence is removed only when it wraps the *whole* input, so a fence inside a
    JSON string value is left alone.

  Any top-level JSON value is accepted, not just an object — `"5"`, `"true"`,
  `"null"` and `"[1,2]"` are all valid JSON documents, and an API that returns
  one should not need a different tool.

  A parse failure is returned as `{:error, message}` carrying Jason's position
  information, so a model that produced malformed JSON can see *where* it broke
  rather than only *that* it broke.
  """

  use Zaq.Engine.Workflows.Action,
    name: "decode_json",
    description: """
    Parse a JSON string and return the value it holds.

    Any top-level JSON value works — an object, an array, or a bare string,
    number, boolean, or null. Surrounding whitespace is ignored and a wrapping
    ```json code fence is stripped, so text copied from documentation or from
    another tool's output parses as-is.

    The result has `decoded` (the parsed value).

    Use this on JSON that arrived as TEXT — a raw HTTP body, a file's contents,
    a field holding an embedded JSON document. Most tools already return
    structured values, so if you can read the fields directly you do not need
    this tool.

    If the string does not parse, the error says where. Fix the JSON and retry
    ONCE; do not invent a value to stand in for what would not parse.
    """,
    schema:
      Zoi.object(%{
        data: Zoi.string(description: "The JSON text to parse")
      }),
    output_schema:
      Zoi.object(%{
        decoded: Zoi.any(description: "The parsed value") |> Zoi.nullable()
      })

  @fence ~r/\A```[a-zA-Z0-9_-]*\s*\n(?<body>.*)\n?```\z/s

  @impl Jido.Action
  def run(%{data: data}, _context) do
    case data |> String.trim() |> strip_fence() |> Jason.decode() do
      {:ok, decoded} -> {:ok, %{decoded: decoded}}
      {:error, error} -> {:error, "not valid JSON: #{Exception.message(error)}"}
    end
  end

  defp strip_fence(data) do
    case Regex.named_captures(@fence, data) do
      %{"body" => body} -> String.trim(body)
      nil -> data
    end
  end
end
