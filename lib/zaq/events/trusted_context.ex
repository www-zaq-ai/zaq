defmodule Zaq.Events.TrustedContext do
  @moduledoc """
  Allowlisted execution context that may cross role and bridge boundaries.

  Callers may provide a larger runtime context, but only canonical identity and an explicit
  permission bypass and narrow BO caller-clearance capability are retained. Runtime dependencies such as the node router and config are
  consumed locally when producing event-builder options and are never stored in this struct.

  Put new permission-bypass decisions in one of two places: top-level
  `context.skip_permissions` before a local call, or `event.opts[:skip_permissions]` before an
  event crosses a role boundary. Actors carry identity; new code should not put authorization
  decisions in actor maps. `from_event/1` still recognizes `actor.skip_permissions` as a
  compatibility input for older BO call paths. Request parameters are never trusted for
  permission bypass.

  `skip_actor_clearance` is issued only by an authorized BO execution boundary
  via `from_bo_actor/1`. It never skips recipient, channel, agent,
  provider, or MCP clearance and is not read from actor or request fields.
  """

  alias Zaq.Accounts.{BOActor, BOAuthorization}
  alias Zaq.Event
  alias Zaq.MapUtils

  @enforce_keys []
  defstruct actor: nil, skip_permissions: false, skip_actor_clearance: false

  @trusted_event_opt_keys [
    :bridge_module,
    :data_source_bridge_module,
    :materialization_verified,
    :skip_permissions,
    :skip_actor_clearance
  ]

  @type t :: %__MODULE__{
          actor: map() | nil,
          skip_permissions: boolean(),
          skip_actor_clearance: boolean()
        }

  @doc """
  Issues canonical context for an authenticated BO execution, not request parameters.

  The shared BO evaluator decides the caller-clearance capability. This factory
  neither grants content permissions nor bypasses destination clearance or policy
  administration. A role without the capability still receives normal context.
  """
  @spec from_bo_actor(term()) :: {:ok, t()} | {:error, :unauthorized}
  def from_bo_actor(actor) do
    case BOAuthorization.authorize(actor, :skip_actor_clearance) do
      {:ok, user} ->
        {:ok, bo_context(user, true)}

      {:error, :unauthorized} ->
        with {:ok, user} <- BOActor.current_user(actor) do
          {:ok, bo_context(user, false)}
        end
    end
  end

  defp bo_context(user, skip_actor_clearance) do
    %__MODULE__{
      actor: %{kind: :bo_user, subject: to_string(user.id), user_id: user.id},
      skip_actor_clearance: skip_actor_clearance
    }
  end

  @doc "Normalizes a runtime context to the fields trusted across service boundaries."
  @spec normalize(t() | map()) :: t()
  def normalize(%__MODULE__{} = context), do: context

  def normalize(context) when is_map(context) do
    actor = MapUtils.fetch(context, :actor)

    %__MODULE__{
      actor: if(is_map(actor), do: actor),
      skip_permissions: Map.get(context, :skip_permissions) == true,
      skip_actor_clearance: Map.get(context, :skip_actor_clearance) == true
    }
  end

  @doc "Builds trusted context from an event envelope, never from its request."
  @spec from_event(Event.t()) :: t()
  def from_event(%Event{} = event) do
    %__MODULE__{
      actor: event.actor,
      skip_permissions:
        Keyword.get(event.opts, :skip_permissions) == true or actor_skip_permissions?(event.actor),
      skip_actor_clearance: Keyword.get(event.opts, :skip_actor_clearance) == true
    }
  end

  defp actor_skip_permissions?(%{skip_permissions: true}), do: true
  defp actor_skip_permissions?(%{"skip_permissions" => true}), do: true
  defp actor_skip_permissions?(_actor), do: false

  @doc "Projects context into options accepted by role event builders."
  @spec event_builder_opts(t() | map(), keyword()) :: keyword()
  def event_builder_opts(context, opts \\ []) when is_map(context) and is_list(opts) do
    trusted = normalize(context)

    base_event_opts = Keyword.get(opts, :event_opts, [])
    context_event_opts = context |> Map.get(:event_opts, []) |> trusted_event_opts()

    opts
    |> Keyword.delete(:actor)
    |> Keyword.put(
      :event_opts,
      event_opts(trusted, Keyword.merge(context_event_opts, base_event_opts))
    )
    |> maybe_put(:actor, trusted.actor)
    |> maybe_put_runtime_dependency(:node_router, context)
    |> maybe_put_runtime_dependency(:config, context)
  end

  defp trusted_event_opts(opts) when is_list(opts),
    do: Keyword.take(opts, @trusted_event_opt_keys)

  defp trusted_event_opts(_opts), do: []

  defp event_opts(%__MODULE__{} = context, opts) do
    Enum.reduce([:skip_permissions, :skip_actor_clearance], opts, fn field, acc ->
      if Map.fetch!(context, field), do: Keyword.put(acc, field, true), else: acc
    end)
  end

  defp maybe_put_runtime_dependency(opts, _key, %__MODULE__{}), do: opts

  defp maybe_put_runtime_dependency(opts, key, context),
    do: maybe_put(opts, key, Map.get(context, key))

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
