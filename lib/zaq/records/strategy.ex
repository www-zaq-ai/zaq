defmodule Zaq.Records.Strategy do
  @moduledoc """
  How one **kind of place** stores and serves a record's bytes.

  A strategy is not one per node, one per file type, or one per caller — it is one per *kind
  of location*. A PDF and a PNG in the same skill bundle share `:skill_bundle`; the same PNG
  in a Mattermost thread is a different strategy, because it is a different node, a different
  resolution and different params.

  ## The only code that may read `params`

  A strategy owns the `params` map on `Zaq.Contracts.Materialization` outright. The facade,
  the role's `Api` clause and every caller treat it as opaque. That encapsulation is the whole
  point: storage layout can change — a new volume, a moved mount, a different on-disk
  convention — without a single edit outside the strategy that owns it.

  ## Capabilities are declared, not inferred

  `c:capabilities/0` states which verbs a strategy supports. A strategy that does not declare
  `:persist` cannot be written through **even if it exports `persist/2`** — the registry
  checks the declaration, not the export. Read-only is therefore the safe default, and making
  something writable is a visible, reviewable edit.

  ## Where implementations live

  Inside the service that owns the bytes — `Zaq.Ingestion.Records.SkillBundleStrategy`, not
  a shared `Zaq.Records.*` bucket. Each role that owns bytes keeps a compile-time registry
  mapping strategy atom to module, and a pair of `Api` clauses that resolve through it. A role
  that owns no bytes (the agent, today) needs neither.

  ## Implementing one

      defmodule Zaq.Ingestion.Records.SkillBundleStrategy do
        @behaviour Zaq.Records.Strategy

        @impl true
        def capabilities, do: [:materialize, :persist]

        @impl true
        def validate_params(%{locator: l, resource_path: p}) when is_binary(l) and is_binary(p),
          do: :ok

        def validate_params(_), do: {:error, :invalid_params}

        @impl true
        def materialize(record, opts), do: ...

        @impl true
        def persist(record, opts), do: ...
      end

  `validate_params/1` runs **before** any I/O, so a malformed descriptor never reaches the
  filesystem or an adapter. Refuse unexpected keys rather than ignoring them — a caller that
  sent one has misunderstood the contract, and silence teaches it that the key works.
  """

  alias Zaq.Contracts.Record

  @type verb :: :materialize | :persist
  @type opts :: keyword()

  @doc "Which verbs this strategy supports. Checked before any dispatch reaches it."
  @callback capabilities() :: [verb()]

  @doc "Validates a descriptor's `params` before any I/O happens."
  @callback validate_params(map()) :: :ok | {:error, term()}

  @doc "Fills the record's content from wherever its descriptor points."
  @callback materialize(Record.t(), opts()) :: {:ok, Record.t()} | {:error, term()}

  @doc "Writes the record's content to where its descriptor points; returns the handle."
  @callback persist(Record.t(), opts()) :: {:ok, Record.t()} | {:error, term()}

  @optional_callbacks materialize: 2, persist: 2

  @verbs [:materialize, :persist]

  @doc """
  Whether `strategy` declares support for `verb`.

  Reads `c:capabilities/0` — the declaration, never the export list, so accidentally exporting
  `persist/2` does not make a read-only strategy writable.
  """
  @spec supports?(module(), verb()) :: boolean()
  def supports?(strategy, verb) when is_atom(strategy) and verb in @verbs do
    verb in strategy.capabilities()
  end

  def supports?(_strategy, _verb), do: false
end
