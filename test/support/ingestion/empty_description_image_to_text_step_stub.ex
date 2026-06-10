defmodule Zaq.Ingestion.EmptyDescriptionImageToTextStepStub do
  @moduledoc false

  def run_single(image_path, output_json, _api_key) do
    image_name = Path.basename(image_path)

    output_json
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(output_json, Jason.encode!(%{image_name => ""}))
    {:ok, "ok"}
  end
end
