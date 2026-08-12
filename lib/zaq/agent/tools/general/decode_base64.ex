defmodule Zaq.Agent.Tools.General.DecodeBase64 do
  @moduledoc """
  Workflow action and ReAct tool: decodes a Base64 string back to its bytes.

  Pure — no I/O, no context keys. The counterpart is
  `Zaq.Agent.Tools.General.EncodeBase64`.

  Decoding is deliberately lenient about the things that trip up real-world
  input:

  - **Whitespace is stripped** first, so a PEM-style blob wrapped across lines
    decodes as-is (`Base` itself rejects embedded newlines).
  - **Padding is optional**, so a JWT segment with its `=` stripped decodes.
  - **The alphabet is auto-detected** by default: standard (`+`, `/`) is tried
    first, then URL-safe (`-`, `_`). They are mutually exclusive, so a value
    that decodes under one cannot be silently misread as the other.

  ## Text and binary

  Base64 carries both, so this decodes both and reports which it got:
  `decoded` holds the raw bytes, `text?` says whether they are valid UTF-8, and
  `byte_size` counts bytes rather than codepoints.

  The two consumers differ in what they can accept, which is why the refusal
  that used to live here is now a description hint rather than a hard error:

  - **In a workflow**, the output travels along a DAG edge straight into the
    next action. Nothing serialises it, so binary passes through intact — which
    is the case that matters for building a file from a decoded payload.
  - **In a ReAct turn**, the result becomes a tool message; `ReqLLM`'s
    `encode_tool_output/1` calls `Jason.encode!/1` on it, which raises on bytes
    that are not valid UTF-8. Binary genuinely cannot travel that path, and no
    encoding here would change that — it would only re-encode the input.

  So the action decodes both, and the tool *description* — read only by the
  model, never by a workflow — steers the model away from calling this on
  binary and toward passing the still-encoded string to a provider that
  materialises it at the write.
  """

  use Zaq.Engine.Workflows.Action,
    name: "decode_base64",
    description: """
    Decode a Base64 string and return the original text.

    Leave variant as "auto" unless you know which alphabet was used — auto
    handles both standard (+ and /) and URL-safe (- and _) input. Padding is
    optional and surrounding whitespace or line breaks are ignored, so JWT
    segments and wrapped PEM-style blobs decode as-is.

    The result has `decoded` (the bytes), `text?` (true when they are readable
    text) and `byte_size`.

    Use this for TEXT. Do NOT use it to save binary — an image, a PDF, a zip —
    to a file: those bytes cannot travel back through this conversation, and
    you will not be able to pass them on to another tool. To persist binary,
    leave it encoded and hand the original Base64 string to the tool that
    creates the file, together with the right mime_type (for example
    "image/png"), which decodes it on the way to storage. Never edit, truncate
    or summarise a Base64 string you are passing along.

    Base64 is an encoding, not encryption. Decoding reveals nothing that was
    protected; treat the result with the same care as the input.
    """,
    schema:
      Zoi.object(%{
        data: Zoi.string(description: "The Base64 string to decode"),
        variant:
          Zoi.enum(["auto", "standard", "url_safe"],
            description:
              ~s|Alphabet: "auto" (try both), "standard" (+ and /), or "url_safe" (- and _)|
          )
          |> Zoi.default("auto")
      }),
    output_schema:
      Zoi.object(%{
        decoded: Zoi.string(description: "The decoded bytes"),
        text?: Zoi.boolean(description: "True when the bytes are valid UTF-8 text"),
        byte_size: Zoi.integer(description: "Size in bytes, not codepoints") |> Zoi.non_negative()
      })

  @whitespace ~r/\s/

  @impl Jido.Action
  def run(%{data: data, variant: variant}, _context) do
    stripped = String.replace(data, @whitespace, "")

    case decode(variant, stripped) do
      {:ok, decoded} -> {:ok, describe(decoded)}
      :error -> {:error, error_message(variant)}
    end
  end

  defp decode("standard", data), do: Base.decode64(data, padding: false)
  defp decode("url_safe", data), do: Base.url_decode64(data, padding: false)

  defp decode("auto", data) do
    case Base.decode64(data, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> Base.url_decode64(data, padding: false)
    end
  end

  defp describe(decoded) do
    %{
      decoded: decoded,
      text?: String.valid?(decoded),
      byte_size: byte_size(decoded)
    }
  end

  defp error_message("auto"),
    do: "not valid Base64 in either the standard or URL-safe alphabet"

  defp error_message(variant), do: "not valid Base64 in the #{variant} alphabet"
end
