defmodule Zaq.Agent.Tools.General.DecodeBase64 do
  @moduledoc """
  ReAct tool: decodes a Base64 string back to text.

  Pure — no I/O, no context keys. The counterpart is
  `Zaq.Agent.Tools.General.EncodeBase64`.

  Decoding is deliberately lenient about the things that trip up real-world
  input, and strict about the one thing that matters:

  - **Whitespace is stripped** first, so a PEM-style blob wrapped across lines
    decodes as-is (`Base` itself rejects embedded newlines).
  - **Padding is optional**, so a JWT segment with its `=` stripped decodes.
  - **The alphabet is auto-detected** by default: standard (`+`, `/`) is tried
    first, then URL-safe (`-`, `_`). They are mutually exclusive, so a value
    that decodes under one cannot be silently misread as the other.
  - **Non-text results are refused.** Base64 often carries binary (an image, a
    zip). This tool returns text, so a payload that is not valid UTF-8 comes
    back as an error naming its size rather than as mojibake the model would
    then reason about as if it were content.
  """

  use Zaq.Engine.Workflows.Action,
    name: "decode_base64",
    description: """
    Decode a Base64 string and return the original text.

    Leave variant as "auto" unless you know which alphabet was used — auto
    handles both standard (+ and /) and URL-safe (- and _) input. Padding is
    optional and surrounding whitespace or line breaks are ignored, so JWT
    segments and wrapped PEM-style blobs decode as-is.

    This tool returns TEXT. If the Base64 carries binary data — an image, a
    PDF, a zip — decoding fails with a message saying so; do not retry it, and
    do not present the payload as if it were readable content.

    Base64 is an encoding, not encryption. Decoding reveals nothing that was
    protected; treat the result with the same care as the input.
    """,
    schema: [
      data: [
        type: :string,
        required: true,
        doc: "The Base64 string to decode"
      ],
      variant: [
        type: {:in, ["auto", "standard", "url_safe"]},
        default: "auto",
        doc: ~s|Alphabet: "auto" (try both), "standard" (+ and /), or "url_safe" (- and _)|
      ]
    ],
    output_schema: [
      decoded: [type: :string, required: true, doc: "The decoded text"]
    ]

  @whitespace ~r/\s/

  @impl Jido.Action
  def run(%{data: data, variant: variant}, _context) do
    stripped = String.replace(data, @whitespace, "")

    case decode(variant, stripped) do
      {:ok, decoded} -> as_text(decoded)
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

  defp as_text(decoded) do
    if String.valid?(decoded) do
      {:ok, %{decoded: decoded}}
    else
      {:error,
       "decoded #{byte_size(decoded)} bytes of binary data, not text — " <>
         "this tool returns text only"}
    end
  end

  defp error_message("auto"),
    do: "not valid Base64 in either the standard or URL-safe alphabet"

  defp error_message(variant), do: "not valid Base64 in the #{variant} alphabet"
end
