defmodule Mix.Tasks.Retrieval.Eval.Embed do
  @moduledoc """
  Generates missing retrieval evaluation embeddings with ZAQ's configured model.

      mix retrieval.eval.embed [--path DIR] [--refresh]

  A normal run fills only missing vectors; `--refresh` replaces every vector after
  a model change or altered text. Questions and relevance expectations remain
  human-authored. This task does not create or alter the knowledge base.
  """

  use Mix.Task

  alias Mix.Tasks.RetrievalEval.Embed, as: Preparation
  alias Mix.Tasks.RetrievalEval.Fixtures
  alias Zaq.Embedding.Client, as: EmbeddingClient

  @shortdoc "Fill retrieval evaluation vectors with the configured embedding model"

  @impl Mix.Task
  def run(args) do
    {opts, positional} = OptionParser.parse!(args, strict: [path: :string, refresh: :boolean])

    if positional != [], do: Mix.raise("Unexpected arguments: #{inspect(positional)}")

    Mix.Task.run("app.start")
    config = configured_embedding!()

    root = opts[:path] || Fixtures.default_path()

    result =
      Preparation.prepare!(root, config.model, config.dimension, &EmbeddingClient.embed/1,
        refresh: opts[:refresh] || false
      )

    shell = Mix.shell()

    shell.info(
      "Prepared #{result.embedded} unique input embeddings; updated #{result.updated} fixture files"
    )

    Enum.each(result.paths, &shell.info/1)
  end

  defp configured_embedding! do
    config = Zaq.System.get_embedding_config()

    if not (is_binary(config.model) and config.model != "" and is_integer(config.dimension) and
              config.dimension > 0 and is_binary(config.endpoint) and config.endpoint != "") do
      Mix.raise(
        "Configure the embedding model, dimension and provider endpoint in ZAQ before generating fixtures"
      )
    end

    config
  end
end
