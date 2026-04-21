defmodule Zaq.Ingestion.Python.Steps.PptxToMd do
  @moduledoc false

  alias Zaq.Ingestion.Python.Runner

  @doc """
  Convert a PPTX file to Markdown using the Python `pptx_to_md.py` script.
  The output path defaults to the same basename with a `.md` extension.
  """
  def run(pptx_path, md_path \\ nil) do
    md_path = md_path || Path.rootname(pptx_path) <> ".md"
    Runner.run("pptx_to_md.py", [pptx_path, "--output", md_path])
  end

  @doc """
  Convert all PPTX files in `input_folder` to Markdown,
  writing results into `output_folder` (preserving sub-folder structure).
  """
  def run_folder(input_folder, output_folder) do
    Runner.run("pptx_to_md.py", ["--input-folder", input_folder, "--output-folder", output_folder])
  end
end
