defmodule ZaqWeb.Live.BO.DataSourceEvents do
  @moduledoc """
  Builds trusted BO data-source events for Channels dispatch.

  BO actor identity is trusted by the LiveView boundary. Super-admin permission bypass is
  projected into allowlisted event options so downstream services do not need to inspect the
  actor map for authorization flags.
  """

  alias Zaq.Event
  alias Zaq.NodeRouter
  alias ZaqWeb.Live.BO.AI.BOActor

  @spec build(atom(), map(), map() | nil, keyword()) :: Event.t()
  def build(action, request, current_user, opts \\ []) when is_atom(action) and is_map(request) do
    actor = BOActor.build(current_user)

    event_opts =
      opts
      |> Keyword.get(:event_opts, [])
      |> Keyword.put(:action, action)
      |> maybe_put_skip_permissions(actor)

    Event.new(request, :channels,
      opts: event_opts,
      actor: actor
    )
  end

  @spec build_and_dispatch(atom(), map(), map() | nil, keyword()) :: Event.t()
  def build_and_dispatch(action, request, current_user, opts \\ []) do
    action
    |> build(request, current_user, opts)
    |> NodeRouter.dispatch()
  end

  defp maybe_put_skip_permissions(opts, %{skip_permissions: true}),
    do: Keyword.put(opts, :skip_permissions, true)

  defp maybe_put_skip_permissions(opts, _actor), do: opts
end
