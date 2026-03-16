defmodule Zaq.Ingestion.Python.Steps.InjectDescriptions do
  @moduledoc false

  alias Zaq.Ingestion.Python.Runner

  def run(md_path, descriptions_json, opts \\ []) do
    args = [md_path, "--descriptions", descriptions_json]
    args = if v = opts[:format], do: args ++ ["--format", "#{v}"], else: args
    Runner.run("inject_descriptions.py", args)
  end
end
