defmodule Zaq.Ingestion.MultiLineImageToTextStepStub do
  @moduledoc false

  # Stub that returns a multi-line description to verify that
  # build_image_markdown/2 blockquotes every line correctly.
  def run_single(image_path, output_json, _api_key) do
    image_name = Path.basename(image_path)
    description = "Line one of description\nLine two of description\nLine three"

    output_json
    |> Path.dirname()
    |> File.mkdir_p!()

    output_json
    |> File.write!(Jason.encode!(%{image_name => description}))

    {:ok, "ok"}
  end
end
