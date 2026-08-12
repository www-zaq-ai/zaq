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

  ## Reporting the shape

  `decoded` holds the value, `type` names its JSON type, and `size` counts the
  keys of an object or the elements of an array (0 for a scalar). A caller
  that must branch — iterate an array, read a field, use a scalar — can do so
  from `type` without inspecting the value first.

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

    The result has `decoded` (the value), `type` (one of "object", "array",
    "string", "number", "boolean", "null") and `size` (keys for an object,
    elements for an array, 0 otherwise).

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
        decoded: Zoi.any(description: "The parsed value") |> Zoi.nullable(),
        type:
          Zoi.enum(["object", "array", "string", "number", "boolean", "null"],
            description: "JSON type of the parsed value"
          ),
        size:
          Zoi.integer(
            description: "Keys for an object, elements for an array, 0 for a scalar or null"
          )
      })

  @fence ~r/\A```[a-zA-Z0-9_-]*\s*\n(?<body>.*)\n?```\z/s

  @impl Jido.Action
  def run(%{data: data}, _context) do
    case data |> String.trim() |> strip_fence() |> Jason.decode() do
      {:ok, decoded} -> {:ok, describe(decoded)}
      {:error, error} -> {:error, "not valid JSON: #{Exception.message(error)}"}
    end
  end

  defp strip_fence(data) do
    case Regex.named_captures(@fence, data) do
      %{"body" => body} -> String.trim(body)
      nil -> data
    end
  end

  defp describe(decoded) do
    %{decoded: decoded, type: type(decoded), size: size(decoded)}
  end

  defp type(value) when is_map(value), do: "object"
  defp type(value) when is_list(value), do: "array"
  defp type(value) when is_binary(value), do: "string"
  defp type(value) when is_number(value), do: "number"
  defp type(value) when is_boolean(value), do: "boolean"
  defp type(nil), do: "null"

  defp size(value) when is_map(value), do: map_size(value)
  defp size(value) when is_list(value), do: length(value)
  defp size(_value), do: 0
end
