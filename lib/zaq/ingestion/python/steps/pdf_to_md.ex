defmodule Zaq.Ingestion.Python.Steps.PdfToMd do
  @moduledoc false

  alias Zaq.Ingestion.Python.Runner

  def run(pdf_path, output_md, images_dir) do
    Runner.run("pdf_to_md.py", [
      pdf_path,
      output_md,
      "--with-images",
      "--images-dir",
      images_dir
    ])
  end
end
