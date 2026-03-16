defmodule Zaq.Ingestion.Python.Steps.XlsxToMd do
  @moduledoc false

  alias Zaq.Ingestion.Python.Runner

  @doc """
  Convert an XLSX/XLS/CSV file to natural-language Markdown using the Python
  `xlsx_to_md.py` script. Each data row becomes a readable sentence.
  The output path defaults to the same basename with a `.md` extension.
  """
  def run(xlsx_path, md_path \\ nil) do
    md_path = md_path || Path.rootname(xlsx_path) <> ".md"
    Runner.run("xlsx_to_md.py", [xlsx_path, "--output", md_path])
  end

  @doc """
  Convert all XLSX/XLS/CSV files in `input_folder` to Markdown,
  writing results into `output_folder` (preserving sub-folder structure).
  """
  def run_folder(input_folder, output_folder) do
    Runner.run("xlsx_to_md.py", ["--input-folder", input_folder, "--output-folder", output_folder])
  end
end
