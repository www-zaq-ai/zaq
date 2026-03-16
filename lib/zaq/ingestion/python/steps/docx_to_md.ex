defmodule Zaq.Ingestion.Python.Steps.DocxToMd do
  @moduledoc false

  alias Zaq.Ingestion.Python.Runner

  @doc """
  Convert a DOCX file to Markdown using the Python `docx_to_md.py` script.
  The output path defaults to the same basename with a `.md` extension.
  """
  def run(docx_path, md_path \\ nil) do
    md_path = md_path || Path.rootname(docx_path) <> ".md"
    Runner.run("docx_to_md.py", [docx_path, "--output", md_path])
  end

  @doc """
  Convert all DOCX files in `input_folder` to Markdown,
  writing results into `output_folder` (preserving sub-folder structure).
  """
  def run_folder(input_folder, output_folder) do
    Runner.run("docx_to_md.py", ["--input-folder", input_folder, "--output-folder", output_folder])
  end
end
