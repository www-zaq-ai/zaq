defmodule Zaq.Ingestion.Records.Registry do
  @moduledoc """
  The strategies this role will run, and the checks every dispatch passes through.

  Ingestion owns bytes on volumes, so it keeps a registry. A role that owns no bytes — the
  agent, today — needs none. Channels will want one when adapter-hosted attachments become
  materializable; copy this module rather than sharing it, because the registry *is* the
  role's statement about what it will do, and sharing one would let a role inherit another's
  reach.

  ## Compile-time on purpose

  The map is resolved with `Application.compile_env/3`, not read at runtime. A runtime-
  registered strategy would be a code path selected by an incoming message, which is exactly
  the shape this seam exists to refuse. Adding a strategy is an edit, a recompile and a
  review.

  Deployments and tests may *add* entries via `config :zaq, :ingestion_record_strategies`;
  the defaults below are merged in and cannot be removed that way.

  ## Three checks before any I/O

    1. **Registered?** An unknown atom is refused here. Because there is no generic "read a
       path" strategy in the map, no caller can construct one — this is what keeps a generic
       action from becoming an arbitrary-file primitive.
    2. **Declared?** The verb must appear in the strategy's `c:Zaq.Records.Strategy.capabilities/0`.
       Checked against the *declaration*, never `function_exported?/3`: a strategy that
       exports `persist/2` without declaring it stays read-only.
    3. **Valid params?** The strategy's own `c:Zaq.Records.Strategy.validate_params/1` runs
       before it is asked to do anything, so a malformed descriptor never reaches a
       filesystem.

  Only then does the strategy run. The registry never reads a key out of `params` — it hands
  the map to the one module allowed to interpret it.
  """

  alias Zaq.Contracts.Materialization
  alias Zaq.Contracts.Record
  alias Zaq.Records.Strategy

  @defaults %{}

  @strategies Map.merge(
                @defaults,
                Application.compile_env(:zaq, :ingestion_record_strategies, %{})
              )

  @doc "The strategy atoms this role will run."
  @spec strategies() :: [atom()]
  def strategies, do: Map.keys(@strategies)

  @doc "Resolves a strategy atom to its module."
  @spec fetch(atom()) :: {:ok, module()} | {:error, :unsupported_strategy}
  def fetch(strategy) when is_atom(strategy) do
    case Map.fetch(@strategies, strategy) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unsupported_strategy}
    end
  end

  @doc """
  Runs `verb` for `record` through the registered strategy, after all three checks.

  Returns the strategy's own error untouched when it declines, so a caller sees why rather
  than a flattened failure.
  """
  @spec run(atom(), Strategy.verb(), Record.t(), keyword()) ::
          {:ok, Record.t()} | {:error, term()}
  def run(strategy, verb, record, opts \\ [])

  def run(
        strategy,
        verb,
        %Record{materialization: %Materialization{params: params}} = record,
        opts
      ) do
    with {:ok, module} <- fetch(strategy),
         :ok <- ensure_declared(module, verb),
         :ok <- module.validate_params(params) do
      apply(module, verb, [record, opts])
    end
  end

  def run(_strategy, _verb, %Record{}, _opts), do: {:error, :not_materializable}

  defp ensure_declared(module, verb) do
    if Strategy.supports?(module, verb), do: :ok, else: {:error, {:unsupported_verb, verb}}
  end
end
