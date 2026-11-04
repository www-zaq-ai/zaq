defmodule Zaq.Hooks do
  @moduledoc """
  Dispatch API for the ZAQ hook system.

  ## `dispatch_sync/3` — intercepting chain (sync, can mutate, can halt)

  Runs all `:sync` hooks registered for `event` in priority order.
  Each hook receives the payload output by the previous hook.

    * `{:ok, payload}`   — chain continues with mutated payload
    * `{:halt, payload}` — chain stops; caller receives `{:halt, payload}`
    * `{:error, reason}` — handler skipped; warning logged; chain continues
    * Exception raised   — caught; warning logged; chain continues with previous payload
    * `:ok`              — pass-through; payload unchanged; chain continues

  ## `dispatch_async/3` — fire-and-forget notification

  Runs all hooks for `event`. Always returns `:ok` immediately.

    * `:sync` hooks run in-process; return value is ignored; errors are caught
    * `:async` hooks are spawned in a `Task`:
      - `node_role: :local` → direct `Task.start/1`
      - `node_role: role`   → `Task.start/1` wrapping `NodeRouter.dispatch/1`

  ## Events

  All events must be registered here and in `@documented_events`.
  Use `documented_events/0` to get the list programmatically.
  `mix hooks.verify` (run automatically in `mix precommit`) will fail if an event
  is dispatched from `lib/` but not present in `documented_events/0`.

  ### Ingestion — `Zaq.Ingestion.Chunk`

  Context for ingestion system events: `%{}`

  #### `:embedding_reset` — `dispatch_async` (observer)

  Fired after `Chunk.reset_table/1` drops and recreates the chunks table with
  a new embedding dimension. Paid features that maintain their own embedding
  columns should listen to this event to reset and re-embed their data.

      %{
        new_dimension: integer()  # the new embedding vector dimension
      }

  ---

  ### Conversations — `Zaq.Engine.Conversations`

  Context for conversation events: `%{}`

  #### `:feedback_provided` — `dispatch_async` (observer)

  Fired after a message rating is created or updated (both positive and
  negative feedback paths). `conversation_history` is always present and
  contains all messages in the conversation ordered by insertion time.

      %{
        message:              %Zaq.Engine.Conversations.Message{},
        rating:               %Zaq.Engine.Conversations.MessageRating{},
        conversation_history: [%Zaq.Engine.Conversations.Message{}],  # mandatory
        rater_attrs:          %{
                                user_id:         Ecto.UUID.t() | nil,
                                channel_user_id: String.t() | nil,
                                rating:          1 | 5,
                                comment:         String.t() | nil
                              }
      }

  ---

  ### Channels — `Zaq.Channels.JidoChatBridge`

  Context for channel events: `%{}`

  #### `:reply_received` — `dispatch_sync` (intercepting)

  Fired when a subscribed chat message arrives in `JidoChatBridge`. Handlers
  may inspect or mutate the post before it is processed further.

      %{
        root_id:  String.t() | nil,  # external thread ID
        user_id:  String.t() | nil,  # author's user ID
        message:  String.t()         # raw message text
      }

  ---

  ## Telemetry

  Every dispatch emits:

      [:zaq, :hooks, :dispatch, :start]  %{event, mode, hook_count}
      [:zaq, :hooks, :dispatch, :stop]   %{event, mode}  measurements: %{duration}
      [:zaq, :hooks, :handler, :error]   %{event, handler, reason}

  ## Module injection (testability)

      # Swap NodeRouter in tests:
      Application.put_env(:zaq, :hooks_node_router_module, MyMockRouter)

      # Swap Registry in tests:
      Application.put_env(:zaq, :hooks_registry_module, MyMockRegistry)
  """

  require Logger

  alias Zaq.Hooks.Hook

  @documented_events [
    :embedding_reset,
    :feedback_provided,
    :reply_received
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Returns the list of all documented hook event atoms."
  @spec documented_events() :: [atom()]
  def documented_events, do: @documented_events

  @doc """
  Runs `:sync` hooks for `event` in priority order, threading the payload.

  Returns `{:ok, payload}` (possibly mutated) or `{:halt, payload}`.
  """
  @spec dispatch_sync(atom(), map(), map()) :: {:ok, map()} | {:halt, map()}
  def dispatch_sync(event, payload, ctx) do
    hooks = registry_mod().lookup(event) |> Enum.filter(&(&1.mode == :sync))
    hook_count = length(hooks)

    start = System.monotonic_time()

    :telemetry.execute(
      [:zaq, :hooks, :dispatch, :start],
      %{},
      %{event: event, mode: :sync, hook_count: hook_count}
    )

    result = run_sync_chain(hooks, event, payload, ctx)

    :telemetry.execute(
      [:zaq, :hooks, :dispatch, :stop],
      %{duration: System.monotonic_time() - start},
      %{event: event, mode: :sync}
    )

    result
  end

  @doc """
  Dispatches `event` to all hooks. Always returns `:ok` immediately.

  `:sync` hooks run in-process (return value ignored). `:async` hooks are
  spawned in Tasks and may execute on remote nodes via `NodeRouter`.
  """
  @spec dispatch_async(atom(), map(), map()) :: :ok
  def dispatch_async(event, payload, ctx) do
    hooks = registry_mod().lookup(event)
    hook_count = length(hooks)

    start = System.monotonic_time()

    :telemetry.execute(
      [:zaq, :hooks, :dispatch, :start],
      %{},
      %{event: event, mode: :async, hook_count: hook_count}
    )

    {sync_hooks, async_hooks} = Enum.split_with(hooks, &(&1.mode == :sync))

    Enum.each(sync_hooks, &run_observer(&1, event, payload, ctx))
    Enum.each(async_hooks, &spawn_async(&1, event, payload, ctx))

    :telemetry.execute(
      [:zaq, :hooks, :dispatch, :stop],
      %{duration: System.monotonic_time() - start},
      %{event: event, mode: :async}
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private — sync chain
  # ---------------------------------------------------------------------------

  defp run_sync_chain([], _event, payload, _ctx), do: {:ok, payload}

  defp run_sync_chain([%Hook{handler: handler} | rest], event, payload, ctx) do
    result =
      try do
        handler.handle(event, payload, ctx)
      rescue
        e ->
          emit_handler_error(event, handler, e)
          Logger.warning("[Hooks] #{inspect(handler)} raised in #{event}: #{inspect(e)}")
          :__error__
      catch
        kind, reason ->
          emit_handler_error(event, handler, {kind, reason})

          Logger.warning(
            "[Hooks] #{inspect(handler)} threw in #{event}: #{inspect({kind, reason})}"
          )

          :__error__
      end

    case result do
      {:ok, new_payload} ->
        run_sync_chain(rest, event, new_payload, ctx)

      {:halt, new_payload} ->
        {:halt, new_payload}

      {:error, reason} ->
        emit_handler_error(event, handler, reason)

        Logger.warning(
          "[Hooks] #{inspect(handler)} returned error in #{event}: #{inspect(reason)}, skipping"
        )

        run_sync_chain(rest, event, payload, ctx)

      :ok ->
        run_sync_chain(rest, event, payload, ctx)

      :__error__ ->
        run_sync_chain(rest, event, payload, ctx)
    end
  end

  # ---------------------------------------------------------------------------
  # Private — after observers and async
  # ---------------------------------------------------------------------------

  defp run_observer(%Hook{handler: handler}, event, payload, ctx) do
    handler.handle(event, payload, ctx)
  rescue
    e ->
      emit_handler_error(event, handler, e)

      Logger.warning(
        "[Hooks] sync observer #{inspect(handler)} raised in #{event}: #{inspect(e)}"
      )
  catch
    kind, reason ->
      emit_handler_error(event, handler, {kind, reason})

      Logger.warning(
        "[Hooks] sync observer #{inspect(handler)} threw in #{event}: #{inspect({kind, reason})}"
      )
  end

  defp spawn_async(%Hook{handler: handler, node_role: :local}, event, payload, ctx) do
    Task.start(fn ->
      try do
        handler.handle(event, payload, ctx)
      rescue
        e ->
          emit_handler_error(event, handler, e)

          Logger.warning(
            "[Hooks] async handler #{inspect(handler)} raised in #{event}: #{inspect(e)}"
          )
      catch
        kind, reason ->
          emit_handler_error(event, handler, {kind, reason})

          Logger.warning(
            "[Hooks] async handler #{inspect(handler)} threw in #{event}: #{inspect({kind, reason})}"
          )
      end
    end)
  end

  defp spawn_async(%Hook{handler: handler, node_role: role}, event, payload, ctx) do
    router = node_router()

    Task.start(fn ->
      try do
        %{module: handler, function: :handle, args: [event, payload, ctx]}
        |> Zaq.Event.new(role, opts: [action: :invoke])
        |> router.dispatch()
      rescue
        e ->
          emit_handler_error(event, handler, e)

          Logger.warning(
            "[Hooks] async NodeRouter dispatch for #{inspect(handler)} raised in #{event}: #{inspect(e)}"
          )
      catch
        kind, reason ->
          emit_handler_error(event, handler, {kind, reason})

          Logger.warning(
            "[Hooks] async NodeRouter dispatch for #{inspect(handler)} threw in #{event}: #{inspect({kind, reason})}"
          )
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private — telemetry + configuration
  # ---------------------------------------------------------------------------

  defp emit_handler_error(event, handler, reason) do
    :telemetry.execute(
      [:zaq, :hooks, :handler, :error],
      %{},
      %{event: event, handler: handler, reason: reason}
    )
  end

  defp registry_mod do
    Application.get_env(:zaq, :hooks_registry_module, Zaq.Hooks.Registry)
  end

  defp node_router do
    Application.get_env(:zaq, :hooks_node_router_module, Zaq.NodeRouter)
  end
end
