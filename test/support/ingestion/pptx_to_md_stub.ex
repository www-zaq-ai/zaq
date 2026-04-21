defmodule Zaq.Ingestion.PptxToMdStub do
  @moduledoc false

  def run(_pptx_path, md_path) do
    File.write!(md_path, "# Slide 1\n\nConverted PPTX content.")
    {:ok, "ok"}
  end
end
