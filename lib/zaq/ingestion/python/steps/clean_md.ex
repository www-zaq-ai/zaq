defmodule Zaq.Ingestion.Python.Steps.CleanMd do
  @moduledoc false

  alias Zaq.Ingestion.Python.Runner

  def run(md_path, images_folder) do
    mapping = Path.join(images_folder, "duplicate_mapping.txt")

    if File.exists?(mapping) do
      Runner.run("clean_md.py", [md_path, "--mapping", mapping])
    else
      {:ok, :skipped}
    end
  end
end
