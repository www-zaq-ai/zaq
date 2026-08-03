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

  The same applies per reference: an id whose document was deleted outside the BO, or that
  the caller may not read, is omitted from the page instead of failing it. That is reported
  through `:on_error` too — a shorter list with no explanation is the hardest version of
  this to diagnose, since nothing distinguishes it from a skill that never had the file.
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
    * `:on_error` — arity-2 function called as `fun.(provider, reason)` when a provider does
      not answer with a page, or answers with one that omits ids that were asked for
      (`{:missing_references, ids}`). Defaults to a no-op.
  """
  @spec list(Skill.t(), keyword()) :: [{String.t(), Record.t()}]
  def list(%Skill{} = skill, opts \\ []) do
    Enum.flat_map(Resources.by_provider(skill), fn {provider, file_ids} ->
      provider
      |> list_files(file_ids, opts)
      |> Enum.map(&{provider, &1})
    end)
  end

  defp list_files(provider, file_ids, opts) do
    node_router = Keyword.get(opts, :node_router, NodeRouter)

    response =
      %{provider: provider, params: %{"file_ids" => file_ids}}
      |> Event.new(:channels, opts: [action: :data_source_list_files])
      |> node_router.dispatch()
      |> Map.get(:response)

    case response do
      {:ok, %RecordPage{records: records} = page} ->
        report_missing(provider, page, opts)
        records

      other ->
        report(provider, other, opts)
        []
    end
  end

  # A provider that does not report `stats.missing` is taken at its word; only an explicit
  # non-empty list is a gap.
  defp report_missing(provider, %RecordPage{stats: %{missing: [_ | _] = missing}}, opts) do
    report(provider, {:missing_references, missing}, opts)
  end

  defp report_missing(_provider, _page, _opts), do: :ok

  defp report(provider, reason, opts) do
    on_error = Keyword.get(opts, :on_error, fn _provider, _reason -> :ok end)
    on_error.(provider, reason)
    :ok
  end
end
