defmodule Zaq.Ingestion.NullByteImageToTextStepStub do
  @moduledoc false

  # Stub that intentionally includes null bytes in the description output,
  # used to verify that sanitize_utf8/1 strips them before persistence.
  def run_single(image_path, output_json, _api_key) do
    image_name = Path.basename(image_path)
    description = "Text\0with\0null\0bytes from #{image_name}"

    output_json
    |> Path.dirname()
    |> File.mkdir_p!()

    output_json
    |> File.write!(Jason.encode!(%{image_name => description}))

    {:ok, "ok"}
  end
end
