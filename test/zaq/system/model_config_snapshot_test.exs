defmodule Zaq.System.ModelConfigSnapshotTest do
  use Zaq.DataCase, async: true

  alias Zaq.System

  test "model selections read one coherent statement even when a write interleaves" do
    for {namespace, read, fields} <- [
          {"rag.translation", fn -> System.get_operation_model_config(:translation) end,
           ~w(credential_id model temperature top_p)},
          {"global.small_model", fn -> System.get_operation_model_config(:small) end,
           ~w(credential_id model temperature top_p)},
          {"rag.reranking", fn -> System.get_rag_model_config(:reranking) end,
           ~w(credential_id model)},
          {"global.decision_model", fn -> System.get_decision_model_config() end,
           ~w(credential_id model)}
        ] do
      old = %{credential_id: 1, model: "old", temperature: 0.2, top_p: 0.7}
      new = %{credential_id: 2, model: "new", temperature: 0.4, top_p: 0.8}

      write = fn values ->
        Repo.transaction(fn ->
          for field <- fields do
            System.set_config(
              "#{namespace}.#{field}",
              Map.fetch!(values, String.to_existing_atom(field))
            )
          end
        end)
      end

      write.(old)
      id = {__MODULE__, make_ref()}
      Process.put(id, true)

      :ok =
        :telemetry.attach(id, [:zaq, :repo, :query], &__MODULE__.interleave_write/4, %{
          owner: self(),
          id: id,
          write: fn -> write.(new) end
        })

      try do
        config = read.()

        assert Map.take(config, Enum.map(fields, &String.to_existing_atom/1)) ==
                 Map.take(old, Enum.map(fields, &String.to_existing_atom/1))

        refute Process.get(id)
        assert read.().model == "new"
      after
        :telemetry.detach(id)
        Process.delete(id)
      end
    end
  end

  test "partial and empty namespaces retain existing defaults without global inheritance" do
    System.set_config("llm.model", "global")

    assert %{credential_id: nil, model: nil, temperature: 0.0, top_p: 0.9} =
             System.get_operation_model_config(:translation)

    System.set_config("rag.translation.model", "partial")

    assert %{credential_id: nil, model: "partial", temperature: 0.0, top_p: 0.9} =
             System.get_operation_model_config(:translation)

    assert %{credential_id: nil, model: nil} = System.get_rag_model_config(:decision)
  end

  # A completed SELECT's telemetry callback deterministically commits a replacement
  # pair before the reader can issue another statement. No production seam or sleeps.
  def interleave_write(_event, _measurements, metadata, %{owner: owner, id: id, write: write}) do
    if self() == owner and String.starts_with?(metadata.query, "SELECT") and
         String.contains?(metadata.query, "system_configs") and Process.delete(id) do
      write.()
    end
  end
end
