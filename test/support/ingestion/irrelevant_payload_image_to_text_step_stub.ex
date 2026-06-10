defmodule Zaq.Ingestion.IrrelevantPayloadImageToTextStepStub do
  @moduledoc false

  def run_single(_image_path, output_json, _api_key) do
    output_json
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(output_json, Jason.encode!(%{"first" => "one", "second" => "two"}))
    {:ok, "ok"}
  end
end
