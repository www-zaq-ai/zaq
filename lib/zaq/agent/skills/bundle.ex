defmodule Zaq.Agent.Skills.Bundle do
  @moduledoc """
  The agent's entire vocabulary for a skill's bundled files: **ask by skill, receive files**.

  Both skill-resource tools reach ingestion through here, so the request maps are built in
  exactly one place and the boundary can be asserted in one place too
  (`test/zaq/agent/skills/isolation_test.exs`).

  ## What this module refuses to know

  Where the files actually live. It sends the skill's opaque locator
  (`Zaq.Agent.Skill.Resources.bundle_locator/1`) to the `:ingestion` role and receives
  `Zaq.Contracts.Record` handles back. It never names a volume, never joins a path onto a
  locator or a `resource_path`, and never receives an absolute path.

  Content is fetched by handing a record back to `Zaq.Records.Materializer`, which reads the
  destination off the record itself. So the *materialize* path names no role and no action
  at all — only the listing still addresses `:ingestion` directly, because asking what a
  bundle contains is not a materialization.

  ## A record is a capability, not an address

  `materialize/3` will only fetch a file that appears in the bundle's **live listing**. The
  model names a `resource_path`; we look it up in the manifest and materialize the record we
  minted, never one assembled from what the model said. A path that is not in the listing is
  not found, and nothing is read. That is what stops a plausible-looking path from becoming
  a read, and it is why the locator is always re-derived from the skill row rather than taken
  from anything that crossed the model boundary.

  ## Failure is degradation, not propagation — for listings only

  `manifest/2` never fails. An unreachable ingestion node, a timeout, a crash mid-dispatch:
  all collapse to an empty listing plus a warning, because the skill's *instructions* are
  the payload that matters and they are already in hand. Losing the manifest costs the model
  one follow-up call; failing the tool costs it the whole skill.

  `materialize/3` is the opposite: content **is** the payload, so errors surface to the
  caller to be turned into a message the model can act on.
  """

  require Logger

  alias Zaq.Agent.Skill
  alias Zaq.Agent.Skill.Resources
  alias Zaq.Agent.Skills.Limits
  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Records.Materializer

  # References first: they are what a skill's instructions actually point at. Assets and
  # scripts follow so a truncated listing drops the least useful entries first.
  @type_order [:references, :assets, :scripts]

  @type entry :: %{name: String.t(), resource_path: String.t(), size: non_neg_integer()}
  @type manifest :: %{resources: [entry()], note: String.t() | nil}

  @doc """
  The metadata listing for a skill's bundle, capped per `resource_listing_max_files`.

  A skill with no bundle returns an empty manifest without dispatching anything — the
  common case, and not worth a round trip.
  """
  @spec manifest(Skill.t(), map()) :: manifest()
  def manifest(%Skill{} = skill, context \\ %{}) do
    case Resources.bundle_locator(skill) do
      :none -> %{resources: [], note: nil}
      {:ok, locator} -> locator |> fetch_listing(context) |> cap(context)
    end
  end

  @doc """
  One resource's UTF-8 text.

  Resolves `resource_path` against the bundle's live listing and materializes the record
  found there — never one built from the argument. A path the listing does not contain is
  `:not_found`, with nothing read.
  """
  @spec materialize(Skill.t(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def materialize(%Skill{} = skill, resource_path, context \\ %{})
      when is_binary(resource_path) do
    with {:ok, locator} <- locator(skill),
         {:ok, record} <- find_record(locator, resource_path, context) do
      fetch_text(record, context)
    end
  end

  # --- Dispatch ---

  defp fetch_listing(locator, context) do
    request = %{bundle: locator}

    case dispatch(request, :list_skill_bundle, context) do
      {:ok, %{} = listing} ->
        flatten(listing)

      other ->
        Logger.warning(
          "[Skills.Bundle] listing unavailable for #{inspect(locator)}, " <>
            "returning instructions without a manifest: #{inspect(other)}"
        )

        []
    end
  end

  defp locator(skill) do
    case Resources.bundle_locator(skill) do
      {:ok, locator} -> {:ok, locator}
      :none -> {:error, :no_bundle}
    end
  end

  # The listing is fetched fresh rather than cached: it is both the lookup and the
  # authorisation check, and a stale one would authorise a file that has since been removed.
  defp find_record(locator, resource_path, context) do
    case dispatch(%{bundle: locator}, :list_skill_bundle, context) do
      {:ok, %{} = listing} -> match_record(listing, resource_path)
      {:error, reason} -> {:error, reason}
      _other -> {:error, :unavailable}
    end
  end

  defp match_record(listing, resource_path) do
    listing
    |> records(@type_order)
    |> Enum.find(&(&1.path == resource_path))
    |> case do
      %Record{} = record -> {:ok, record}
      nil -> {:error, :not_found}
    end
  end

  # `as: :text` is what keeps base64 out of a context window, and the read cap is applied
  # here so the ingestion side refuses before it reads rather than after it ships.
  defp fetch_text(record, context) do
    materializer = Map.get(context, :materializer, Materializer)

    record
    |> materializer.materialize(
      as: :text,
      max_bytes: Limits.get(:resource_read_max_bytes, limits_opts(context)),
      node_router: Map.get(context, :node_router, NodeRouter)
    )
    |> case do
      {:ok, %Record{content: text}} when is_binary(text) -> {:ok, text}
      {:ok, %Record{}} -> {:error, :unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  # A dispatch that raises or exits (a downed node, a call timeout) must read the same as
  # one that returns an error — the caller decides what to do about it either way.
  defp dispatch(request, action, context) do
    node_router = Map.get(context, :node_router, NodeRouter)

    request
    |> Event.new(:ingestion, opts: [action: action])
    |> node_router.dispatch()
    |> Map.get(:response)
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # --- Shaping ---

  defp flatten(listing) do
    Enum.flat_map(@type_order, fn type ->
      listing
      |> Map.get(type, [])
      |> Enum.map(&to_entry/1)
    end)
  end

  defp records(listing, types) do
    Enum.flat_map(types, fn type -> Map.get(listing, type, []) end)
  end

  # Records are the transport contract, not the model-facing one. A `Record` encodes ~20
  # mostly-nil keys; three fields are what the model needs to decide whether to spend a call
  # on a file. `modified_at` is dropped too — a timestamp is context it cannot act on.
  defp to_entry(%Record{name: name, path: resource_path, size: size}) do
    %{name: name, resource_path: resource_path, size: size}
  end

  defp cap(entries, context) do
    max = Limits.get(:resource_listing_max_files, limits_opts(context))
    total = length(entries)

    if total > max do
      %{
        resources: Enum.take(entries, max),
        note:
          "Showing #{max} of #{total} bundled files. Ask for a specific path if what you " <>
            "need is not listed."
      }
    else
      %{resources: entries, note: nil}
    end
  end

  defp limits_opts(context), do: Map.get(context, :limits_opts, [])
end
