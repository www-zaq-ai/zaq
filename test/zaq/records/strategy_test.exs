defmodule Zaq.Records.StrategyTest do
  use ExUnit.Case, async: true

  alias Zaq.Records.Limits
  alias Zaq.Records.Strategy

  defmodule ReadOnly do
    @behaviour Strategy

    @impl true
    def capabilities, do: [:materialize]

    @impl true
    def validate_params(%{locator: locator}) when is_binary(locator), do: :ok
    def validate_params(_), do: {:error, :invalid_params}

    @impl true
    def materialize(record, _opts), do: {:ok, record}
  end

  defmodule ReadWrite do
    @behaviour Strategy

    @impl true
    def capabilities, do: [:materialize, :persist]

    @impl true
    def validate_params(_params), do: :ok

    @impl true
    def materialize(record, _opts), do: {:ok, record}

    @impl true
    def persist(record, _opts), do: {:ok, record}
  end

  describe "supports?/2" do
    test "reads the declared capabilities" do
      assert Strategy.supports?(ReadWrite, :materialize)
      assert Strategy.supports?(ReadWrite, :persist)
      assert Strategy.supports?(ReadOnly, :materialize)
    end

    # A strategy that never declared :persist must not be writable through, even if some
    # future edit accidentally exports persist/2. Declaration is the contract.
    test "refuses a verb the strategy did not declare" do
      refute Strategy.supports?(ReadOnly, :persist)
    end

    test "refuses an unknown verb" do
      refute Strategy.supports?(ReadWrite, :delete)
    end
  end

  defmodule ConfigStub do
    @moduledoc false
    def get(:zaq, :records, _default, _opts), do: Process.get(:records_stub)
    def get(app, key, default, _opts), do: Application.get_env(app, key, default)
  end

  defp stub(overrides) do
    Process.put(:records_stub, overrides)
    ConfigStub
  end

  describe "Limits" do
    test "transport ceiling defaults to 16 MiB" do
      assert Limits.get(:transport_max_bytes) == 16 * 1024 * 1024
    end

    test "is overridable through app config" do
      assert Limits.get(:transport_max_bytes, config: stub(%{transport_max_bytes: 42})) == 42
    end

    test "raises on an unknown limit rather than returning nil" do
      assert_raise KeyError, fn -> Limits.get(:nonexistent) end
    end
  end
end
