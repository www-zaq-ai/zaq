defmodule Zaq.Support.Records.TestStrategies do
  @moduledoc """
  Strategies registered only in `:test`, used to exercise role plumbing without depending on
  a real storage backend.

  They exist because the registry is resolved at **compile time** — there is no runtime
  registration to stub, by design. `config/test.exs` merges these in alongside the real
  strategies, so registry tests can cover the unknown-strategy, undeclared-verb and
  invalid-params paths without reaching a filesystem.
  """

  defmodule ReadWrite do
    @moduledoc "Echoes back, recording what it was called with."
    @behaviour Zaq.Records.Strategy

    @impl true
    def capabilities, do: [:materialize, :persist]

    @impl true
    def validate_params(%{ok: false}), do: {:error, :invalid_params}
    def validate_params(_params), do: :ok

    @impl true
    def materialize(record, opts) do
      send(self(), {:materialized, record, opts})
      {:ok, %{record | content: "materialized"}}
    end

    @impl true
    def persist(record, opts) do
      send(self(), {:persisted, record, opts})
      {:ok, %{record | content: nil}}
    end
  end

  defmodule ReadOnly do
    @moduledoc "Declares only `:materialize`, but deliberately exports `persist/2` anyway."
    @behaviour Zaq.Records.Strategy

    @impl true
    def capabilities, do: [:materialize]

    @impl true
    def validate_params(_params), do: :ok

    @impl true
    def materialize(record, _opts), do: {:ok, record}

    # Exported on purpose: the registry must refuse this because it is not *declared*, not
    # because it is missing. Capability checks that fall back to `function_exported?/3` pass
    # this by mistake. `@impl` is compile-time metadata and has no bearing on the runtime
    # capability check, which reads `capabilities/0` — so this stays a real test.
    @impl true
    def persist(record, _opts), do: {:ok, record}
  end
end
