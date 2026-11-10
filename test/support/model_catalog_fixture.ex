defmodule Zaq.TestSupport.ModelCatalogFixture do
  @moduledoc """
  Builds a small valid base catalog for synchronous model-overlay tests.

  The real loader still parses and validates the snapshot. The temporary file is
  removed on exit; callers pass the returned options to the loader and restore
  any shared catalog they load.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  def minimal_source_opts! do
    {:ok, provider} = LLMDB.provider(:openai)
    {:ok, model} = LLMDB.model(:openai, "gpt-4.1-mini")
    path = Path.join(System.tmp_dir!(), "zaq-catalog-#{Ecto.UUID.generate()}.json")
    on_exit(fn -> File.rm(path) end)

    LLMDB.Snapshot.write!(
      path,
      LLMDB.Snapshot.from_engine_snapshot(%{
        version: 2,
        generated_at: DateTime.to_iso8601(DateTime.utc_now()),
        providers: %{
          "openai" => Map.put(Map.from_struct(provider), :models, %{model.id => model})
        }
      })
    )

    [snapshot_source: {:file, path}]
  end
end
