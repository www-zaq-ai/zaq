defmodule Zaq.Ingestion.Python.Steps.ImageToText do
  @moduledoc false

  alias Zaq.Ingestion.Python.Runner

  def run(images_folder, output_json, api_key) do
    Runner.run("image_to_text.py", [
      "--folder",
      images_folder,
      "--output",
      output_json,
      "--api-key",
      api_key
    ])
  end

  def run_single(image_path, output_json, api_key) do
    Runner.run("image_to_text.py", [
      image_path,
      "--output",
      output_json,
      "--api-key",
      api_key
    ])
  end
end
