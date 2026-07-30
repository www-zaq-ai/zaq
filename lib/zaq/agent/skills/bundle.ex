defmodule Zaq.Agent.Skills.Bundle do
  @moduledoc """
  The agent's entire vocabulary for a skill's bundled files: **ask by skill, receive files**.

  Both skill-resource tools reach ingestion through here, so the request maps are built in
  exactly one place and the boundary can be asserted in one place too
  (`test/zaq/agent/skills/isolation_test.exs`).

  ## What this module refuses to know

  Where the files actually live. It sends the skill's opaque locator
  (`Zaq.Agent.Skill.Resources.bundle_locator/1`) to the `:ingestion` role and receives
  either metadata or text. It never names a volume, never joins a path onto a locator or a
  `resource_path`, and never receives an absolute path — `Zaq.Ingestion.ResourceBundle`
  strips those before they cross. That is what lets storage layout change without a single
  edit in this domain.

  Both strings are pass-through: whatever the manifest reported as `resource_path` is what
  goes back on a read, byte for byte. Rewriting it here would let a caller reach a file it
  did not name.

  ## Failure is degradation, not propagation — for listings only

  `manifest/2` never fails. An unreachable ingestion node, a timeout, a crash mid-dispatch:
  all collapse to an empty listing plus a warning, because the skill's *instructions* are
  the payload that matters and they are already in hand. Losing the manifest costs the model
  one follow-up call; failing the tool costs it the whole skill.

  `read_text/3` is the opposite: content **is** the payload, so errors surface to the caller
  to be turned into a message the model can act on.
  """

  require Logger

  alias Zaq.Agent.Skill
  alias Zaq.Agent.Skill.Resources
  alias Zaq.Agent.Skills.Limits
  alias Zaq.Event
  alias Zaq.NodeRouter

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

  `resource_path` is passed through verbatim; validation belongs to the ingestion side,
  which is the only party that knows what it resolves against.
  """
  @spec read_text(Skill.t(), String.t(), map()) :: {:ok, String.t()} | {:error, atom()}
  def read_text(%Skill{} = skill, resource_path, context \\ %{})
      when is_binary(resource_path) do
    case Resources.bundle_locator(skill) do
      :none -> {:error, :no_bundle}
      {:ok, locator} -> dispatch_read(locator, resource_path, context)
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

  defp dispatch_read(locator, resource_path, context) do
    request = %{bundle: locator, resource: resource_path}

    case dispatch(request, :read_skill_bundle_resource, context) do
      {:ok, text} when is_binary(text) -> {:ok, text}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :unavailable}
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

  # `modified` is dropped: a timestamp is context the model cannot act on. Name, path and
  # size are exactly what it needs to decide whether to spend a call on the file.
  defp to_entry(%{name: name, resource_path: resource_path, size: size}) do
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
