defmodule Zaq.Agent.Tools.General.EncodeJson do
  @moduledoc """
  Workflow action and ReAct tool: serialises a value to a JSON string.

  Pure — no I/O, no context keys. The counterpart is
  `Zaq.Agent.Tools.General.DecodeJson`.

  The value comes in as `data` and goes out as `encoded`, a string. `pretty`
  switches between the compact form (what an API wants on the wire) and the
  indented form (what a human reads).

  Not everything is encodable. Jason raises on tuples, PIDs, structs without a
  `Jason.Encoder`, and binaries that are not valid UTF-8, so encoding failures
  are returned as `{:error, message}` rather than allowed to escape — a
  workflow step gets a routable failure instead of a crashed run.

  ## Where this fits

  In a workflow, the DAG edge already carries structured values, so an action
  that needs a map hands it a map — this tool is for the moment a *string* is
  required: an `http_request` raw body, a file to write, a payload to sign.

  In a ReAct turn, the model writes the parameters itself, so `data` arrives as
  the shape the model typed. That makes this the tool for handing a value on to
  something that speaks JSON text, not a way to inspect a value the model
  already holds.
  """

  use Zaq.Engine.Workflows.Action,
    name: "encode_json",
    description: """
    Serialise a value to a JSON string and return the text.

    Pass the value as `data` — an object, an array, or a single string, number,
    boolean, or null. It is encoded as-is: nothing is added, reordered, or
    dropped.

    Set `pretty` to true only when a person will read the output. Leave it
    false for anything sent to an API, hashed, or signed — the compact form is
    what those expect.

    The result has `encoded` (the JSON text) and `byte_size`.

    Use this when another tool needs JSON as a STRING — a raw HTTP body, a file
    to write, a payload to sign. Do NOT use it to look at a value you already
    have: you can read it directly, and re-encoding only costs a turn.
    """,
    schema:
      Zoi.object(%{
        data:
          Zoi.any(
            description: "The value to encode: an object, array, string, number, boolean, or null"
          )
          |> Zoi.nullable(),
        pretty:
          Zoi.boolean(
            description:
              "True for indented, human-readable output; false for the compact wire form"
          )
          |> Zoi.default(false)
      }),
    output_schema:
      Zoi.object(%{
        encoded: Zoi.string(description: "The JSON text"),
        byte_size: Zoi.integer(description: "Size of the JSON text in bytes, not codepoints")
      })

  @impl Jido.Action
  def run(%{data: data} = params, _context) do
    case Jason.encode(data, pretty: Map.get(params, :pretty, false)) do
      {:ok, encoded} -> {:ok, %{encoded: encoded, byte_size: byte_size(encoded)}}
      {:error, error} -> {:error, "could not encode as JSON: #{Exception.message(error)}"}
    end
  end
end
