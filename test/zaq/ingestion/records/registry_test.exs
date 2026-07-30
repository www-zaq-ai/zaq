defmodule Zaq.Ingestion.Records.RegistryTest do
  use ExUnit.Case, async: true

  alias Zaq.Contracts.Materialization
  alias Zaq.Contracts.Record
  alias Zaq.Ingestion.Records.Registry

  defp record(strategy, params \\ %{}) do
    %Record{
      id: "r",
      kind: :file,
      materialization: Materialization.new(:ingestion, strategy, params: params)
    }
  end

  describe "run/4" do
    test "delegates to the registered strategy" do
      assert {:ok, %Record{content: "materialized"}} =
               Registry.run(:test_read_write, :materialize, record(:test_read_write))

      assert_received {:materialized, %Record{}, _opts}
    end

    test "passes opts through to the strategy" do
      Registry.run(:test_read_write, :materialize, record(:test_read_write), timeout: 5)

      assert_received {:materialized, %Record{}, [timeout: 5]}
    end

    test "supports the persist verb" do
      assert {:ok, %Record{content: nil}} =
               Registry.run(:test_read_write, :persist, record(:test_read_write))

      assert_received {:persisted, %Record{}, _opts}
    end
  end

  describe "refusals" do
    # The registry is the security boundary: there is no generic "read a path" strategy, so
    # an unregistered atom must never reach code that touches storage.
    test "an unregistered strategy is refused without reaching a strategy" do
      assert {:error, :unsupported_strategy} =
               Registry.run(:definitely_not_registered, :materialize, record(:whatever))

      refute_received {:materialized, _, _}
    end

    # ReadOnly exports persist/2 but does not declare it. Declaration is the contract, so a
    # capability check based on exports would wrongly allow this.
    test "a verb the strategy did not declare is refused even though it is exported" do
      assert function_exported?(Zaq.Support.Records.TestStrategies.ReadOnly, :persist, 2)

      assert {:error, {:unsupported_verb, :persist}} =
               Registry.run(:test_read_only, :persist, record(:test_read_only))
    end

    test "invalid params are refused before the strategy runs" do
      assert {:error, :invalid_params} =
               Registry.run(
                 :test_read_write,
                 :materialize,
                 record(:test_read_write, %{ok: false})
               )

      refute_received {:materialized, _, _}
    end

    test "a record with no descriptor is refused" do
      assert {:error, :not_materializable} =
               Registry.run(:test_read_write, :materialize, %Record{id: "r", kind: :file})
    end
  end

  describe "fetch/1" do
    test "resolves a registered strategy to its module" do
      assert {:ok, Zaq.Support.Records.TestStrategies.ReadWrite} =
               Registry.fetch(:test_read_write)
    end

    test "refuses an unregistered strategy" do
      assert {:error, :unsupported_strategy} = Registry.fetch(:nope)
    end
  end
end
