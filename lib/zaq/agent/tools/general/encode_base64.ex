defmodule Zaq.Agent.Tools.General.EncodeBase64 do
  @moduledoc """
  ReAct tool: encodes text as Base64.

  Pure — no I/O, no context keys. The counterpart is
  `Zaq.Agent.Tools.General.DecodeBase64`.

  Two alphabets are supported, because APIs disagree about which they want:

  - `"standard"` (RFC 4648 §4) uses `+` and `/` — the default, and what an
    HTTP `Basic` credential or an embedded attachment expects.
  - `"url_safe"` (RFC 4648 §5) uses `-` and `_` — what JWTs and query
    parameters expect, since `+` and `/` would need escaping.

  Padding (`=`) can be dropped with `padding: false`, which JWT segments and
  some APIs require.
  """

  use Zaq.Engine.Workflows.Action,
    name: "encode_base64",
    description: """
    Encode text as Base64 and return the encoded string.

    Set variant to "url_safe" when the value goes in a URL, a query parameter,
    or a JWT segment — that alphabet uses "-" and "_" instead of "+" and "/".
    Otherwise leave it as "standard".

    Set padding to false to drop trailing "=" characters, which JWT segments
    and some APIs require.

    This tool only encodes text you already have. It does not fetch anything
    and it does not encrypt — Base64 is an encoding, not a secret, so anyone
    holding the result can read the original value.
    """,
    schema: [
      data: [
        type: :string,
        required: true,
        doc: "Text to encode"
      ],
      variant: [
        type: {:in, ["standard", "url_safe"]},
        default: "standard",
        doc: ~s|Alphabet: "standard" (+ and /) or "url_safe" (- and _)|
      ],
      padding: [
        type: :boolean,
        default: true,
        doc: ~s|Whether to append "=" padding characters|
      ]
    ],
    output_schema: [
      encoded: [type: :string, required: true, doc: "The Base64-encoded string"]
    ]

  @impl Jido.Action
  def run(%{data: data, variant: variant, padding: padding}, _context) do
    {:ok, %{encoded: encode(variant, data, padding)}}
  end

  defp encode("standard", data, padding), do: Base.encode64(data, padding: padding)
  defp encode("url_safe", data, padding), do: Base.url_encode64(data, padding: padding)
end
