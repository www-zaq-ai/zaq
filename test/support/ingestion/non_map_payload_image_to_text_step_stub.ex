defmodule Zaq.Ingestion.NonMapPayloadImageToTextStepStub do
  @moduledoc false

  # Stub that returns a JSON list instead of a map, used to exercise the
  # pick_image_description/2 non-map clause in DocumentProcessor.
  def run_single(_image_path, output_json, _opts) do
    output_json
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(output_json, Jason.encode!(["not", "a", "map"]))
    {:ok, "ok"}
  end
end
