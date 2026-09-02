defmodule Zaq.Events.TrustedContext do
  @moduledoc """
  Allowlisted execution context that may cross role and bridge boundaries.

  Callers may provide a larger runtime context, but only canonical identity and an explicit
  permission bypass are retained. Runtime dependencies such as the node router and config are
  consumed locally when producing event-builder options and are never stored in this struct.
  """

  alias Zaq.Event
  alias Zaq.MapUtils

  @enforce_keys []
  defstruct actor: nil, skip_permissions: false

  @trusted_event_opt_keys [
    :bridge_module,
    :data_source_bridge_module,
    :materialization_verified,
    :skip_permissions
  ]

  @type t :: %__MODULE__{actor: map() | nil, skip_permissions: boolean()}

  @doc "Normalizes a runtime context to the fields trusted across service boundaries."
  @spec normalize(t() | map()) :: t()
  def normalize(%__MODULE__{} = context), do: context

  def normalize(context) when is_map(context) do
    actor = MapUtils.fetch(context, :actor)

    %__MODULE__{
      actor: if(is_map(actor), do: actor),
      skip_permissions: Map.get(context, :skip_permissions) == true
    }
  end

  @doc "Builds trusted context from an event envelope, never from its request."
  @spec from_event(Event.t()) :: t()
  def from_event(%Event{} = event) do
    %__MODULE__{
      actor: event.actor,
      skip_permissions:
        Keyword.get(event.opts, :skip_permissions) == true or actor_skip_permissions?(event.actor)
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

  defp event_opts(%__MODULE__{skip_permissions: true}, opts),
    do: Keyword.put(opts, :skip_permissions, true)

  defp event_opts(%__MODULE__{}, opts), do: opts

  defp maybe_put_runtime_dependency(opts, _key, %__MODULE__{}), do: opts

  defp maybe_put_runtime_dependency(opts, key, context),
    do: maybe_put(opts, key, Map.get(context, key))

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
