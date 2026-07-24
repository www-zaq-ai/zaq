defmodule Zaq.Ingestion.Python.Steps.MdToDoc do
  @moduledoc false

  alias Zaq.Ingestion.Python.Runner

  @default_format "pdf"

  @doc """
  Convert a single Markdown file to a document using the Python `md_to_doc.py`
  script (the inverse of the `*_to_md.py` converters).

  The output path defaults to the same basename with the target format's
  extension (e.g. `report.md` → `report.pdf`).

  ## Options

    * `:to` - target format (default: `"pdf"`).
    * `:output` - explicit output path (overrides the default basename).
    * `:toc` - when `true`, add a table-of-contents page and PDF bookmarks.
    * `:on_progress` - forwarded to `Runner.run/3`.
  """
  def run(md_path, opts \\ []) do
    fmt = opts[:to] || @default_format
    output = opts[:output] || Path.rootname(md_path) <> ".#{fmt}"

    args =
      [md_path, "--to", fmt, "--output", output]
      |> maybe_add_toc(opts[:toc])

    Runner.run("md_to_doc.py", args, Keyword.take(opts, [:on_progress]))
  end

  @doc """
  Convert all Markdown files in `input_folder` to documents, writing results
  into `output_folder` (preserving sub-folder structure).

  See `run/2` for supported `opts` (`:to`, `:toc`, `:on_progress`).
  """
  def run_folder(input_folder, output_folder, opts \\ []) do
    fmt = opts[:to] || @default_format

    args =
      ["--input-folder", input_folder, "--output-folder", output_folder, "--to", fmt]
      |> maybe_add_toc(opts[:toc])

    Runner.run("md_to_doc.py", args, Keyword.take(opts, [:on_progress]))
  end

  defp maybe_add_toc(args, true), do: args ++ ["--toc"]
  defp maybe_add_toc(args, _), do: args
end
