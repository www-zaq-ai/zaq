defmodule Zaq.Agent.Skill.ReferenceFiles do
  @moduledoc """
  Resolves a skill's stored file references into records from their datasource.

  The skill row stores `{file_id, provider}` and nothing else — the datasource owns names,
  sizes and mime types, so a copy on the skill would go stale the moment a file is renamed.
  Turning those ids into something displayable therefore takes a dispatch, which is why this
  is a separate module from the pure `Zaq.Agent.Skill.Resources`.

  Both readers of a skill's files use it — the BO resource table and the `load_skill` tool —
  so the grouping, the dispatch and the degradation rule below exist once rather than per
  caller.

  ## Degradation

  A provider that cannot be reached yields no records for its references rather than an
  error. A skill whose instructions do not need a file must stay loadable when ingestion is
  down, and the BO resource table must render rather than crash the page. Callers that want
  to report the failure pass `:on_error`.
  """

  alias Zaq.Agent.Skill
  alias Zaq.Agent.Skill.Resources
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Event
  alias Zaq.NodeRouter

  @doc """
  The skill's reference files as `{provider, record}` pairs, one dispatch per provider.

  The provider is returned alongside each record rather than read back off it: it is the
  address half that `download_document` takes, and the group key is authoritative where a
  record's `attributes` may not be.

  ## Options

    * `:node_router` — module used to dispatch, defaults to `Zaq.NodeRouter`.
    * `:on_error` — arity-2 function called as `fun.(provider, response)` when a provider
      does not answer with a page. Defaults to a no-op.
  """
  @spec list(Skill.t(), keyword()) :: [{String.t(), Record.t()}]
  def list(%Skill{} = skill, opts \\ []) do
    Enum.flat_map(Resources.by_provider(skill), fn {provider, file_ids} ->
      provider
      |> list_files(file_ids, opts)
      |> Enum.map(&{provider, &1})
    end)
  end

  @doc """
  The skill's reference files as records, dropping the provider.

  For callers that only display the files. Options are the same as `list/2`.
  """
  @spec records(Skill.t(), keyword()) :: [Record.t()]
  def records(%Skill{} = skill, opts \\ []) do
    skill |> list(opts) |> Enum.map(fn {_provider, record} -> record end)
  end

  defp list_files(provider, file_ids, opts) do
    node_router = Keyword.get(opts, :node_router, NodeRouter)

    response =
      %{provider: provider, params: %{"file_ids" => file_ids}}
      |> Event.new(:channels, opts: [action: :data_source_list_files])
      |> node_router.dispatch()
      |> Map.get(:response)

    case response do
      {:ok, %RecordPage{records: records}} ->
        records

      other ->
        on_error = Keyword.get(opts, :on_error, fn _provider, _response -> :ok end)
        on_error.(provider, other)
        []
    end
  end
end
