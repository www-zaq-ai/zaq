defmodule Zaq.Ingestion.ImageToTextStepStub do
  @moduledoc false

  def run_single(image_path, output_json, _api_key) do
    image_name = Path.basename(image_path)
    description = "Detected text from #{image_name}"

    output_json
    |> Path.dirname()
    |> File.mkdir_p!()

    output_json
    |> File.write!(Jason.encode!(%{image_name => description}))

    {:ok, "ok"}
  end
end
