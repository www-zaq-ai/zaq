defmodule Zaq.Ingestion.Python.Steps.ImageDedup do
  @moduledoc false

  alias Zaq.Ingestion.Python.Runner

  def run(images_folder, opts \\ []) do
    args = [images_folder, "--delete"]
    args = if v = opts[:threshold], do: args ++ ["--threshold", "#{v}"], else: args
    Runner.run("image_dedup.py", args)
  end
end
