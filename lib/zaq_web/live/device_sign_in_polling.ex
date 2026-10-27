defmodule ZaqWeb.Live.DeviceSignInPolling do
  @moduledoc """
  Shared socket-private sign-in observation and timer ownership. Reopening the same attempt
  preserves its timer; switching or stopping cancels it. A fresh generation for
  each tick rejects messages already queued before cancellation or consumption.
  The observer admits one request at a time, replaces challenges, delivers completion
  once per generation and applies normalized dismissal policy. Authorized consumers
  supply command and completion callbacks; no domain modules are invoked here.
  Opaque refs, callbacks, generations and timers never enter presentation assigns.
  """
  alias Phoenix.LiveView
  require LiveView
  alias Phoenix.Component

  @doc "Opens a normalized observation using a caller-owned authorized command boundary."
  def open(socket, view, opts) do
    case socket.private[:sign_in_observer] do
      %{ref: ref} when not is_nil(ref) and is_map(view) and ref == view.ref ->
        apply_view(socket, view, false)

      _ ->
        socket = dismiss(socket)

        state = %{
          generation: make_ref(),
          ref: nil,
          in_flight: nil,
          operation: nil,
          cancel_requested: false,
          attempts: 0,
          completed: false,
          dispatch: Keyword.fetch!(opts, :dispatch),
          view_key: Keyword.fetch!(opts, :view_key),
          max_observations: Keyword.get(opts, :max_observations, :infinity),
          on_complete: Keyword.get(opts, :on_complete, fn socket, _ -> socket end),
          on_error: Keyword.get(opts, :on_error, fn socket, _, _ -> socket end),
          retry_errors: Keyword.get(opts, :retry_errors, false),
          failure_summary: Keyword.get(opts, :failure_summary),
          begin_params: Keyword.get(opts, :begin_params, %{}),
          view: nil
        }

        socket |> LiveView.put_private(:sign_in_observer, state) |> apply_view(view, false)
    end
  end

  @doc "Dispatches one command asynchronously; overlapping commands are ignored."
  def request(
        %{private: %{sign_in_observer: %{view: %{confirmation: %{external_id: _}}}}} = socket,
        :confirm
      ),
      do: dispatch_request(socket, :confirm)

  def request(socket, :confirm), do: socket

  def request(%{private: %{sign_in_observer: %{in_flight: id} = state}} = socket, :cancel)
      when not is_nil(id),
      do: LiveView.put_private(socket, :sign_in_observer, %{state | cancel_requested: true})

  def request(socket, command), do: dispatch_request(socket, command)

  defp dispatch_request(socket, command) do
    case socket.private[:sign_in_observer] do
      %{in_flight: nil} = state ->
        {socket, state} = prepare_request(socket, state, command)
        id = make_ref()
        dispatch = state.dispatch
        command = resolve_command(command, state)

        socket
        |> stop(:sign_in_observer_timer)
        |> LiveView.put_private(:sign_in_observer, %{
          state
          | in_flight: id,
            operation: elem(command, 0)
        })
        |> LiveView.start_async({:sign_in, state.generation, id}, fn ->
          {dispatch, dispatch.(command)}
        end)

      _ ->
        socket
    end
  end

  defp prepare_request(socket, state, :retry) do
    view =
      Map.merge(state.view || %{}, %{
        status: "pending",
        challenge: nil,
        confirmation: nil,
        summary: "Checking connection"
      })

    state = %{state | generation: make_ref(), attempts: 0, completed: false, view: view}
    {Component.assign(socket, state.view_key, presentation(view)), state}
  end

  defp prepare_request(socket, state, _), do: {socket, state}

  defp resolve_command(:observe, state), do: {:observe, state.ref}
  defp resolve_command(:cancel, state), do: {:cancel, state.ref}

  defp resolve_command(:confirm, state),
    do: {:confirm, state.ref, state.view.confirmation.external_id}

  defp resolve_command(:retry, %{view: %{retry: :resume}} = state),
    do: {:begin, Map.put(state.begin_params, :resume, state.ref)}

  defp resolve_command(:retry, state), do: {:begin, state.begin_params}
  defp resolve_command(command, _), do: command

  @doc "Consumes one private timer tick before issuing the next observation."
  def tick(socket, generation, tick) do
    case consume(socket, :sign_in_observer_timer, generation, tick) do
      {:ok, socket} -> request(socket, :observe)
      :stale -> socket
    end
  end

  @doc "Admits one current async result; abandoned cancellable refs are disposed separately."
  def result(socket, generation, id, result) do
    case socket.private[:sign_in_observer] do
      %{generation: ^generation, in_flight: ^id} = state when not is_nil(id) ->
        socket = LiveView.put_private(socket, :sign_in_observer, %{state | in_flight: nil})
        socket = apply_view(socket, result_view(result, state))

        socket =
          case result do
            {:ok, {_, {:error, reason}}} -> state.on_error.(socket, state.operation, reason)
            _ -> socket
          end

        if state.cancel_requested, do: cancel_after_result(socket), else: socket

      _ ->
        discard_stale(socket, result)
        socket
    end
  end

  defp cancel_after_result(%{private: %{sign_in_observer: %{ref: ref} = state}} = socket)
       when not is_nil(ref),
       do:
         socket
         |> LiveView.put_private(:sign_in_observer, %{state | cancel_requested: false})
         |> request(:cancel)

  defp cancel_after_result(socket), do: socket

  defp result_view({:ok, {_dispatch, {:ok, view}}}, _), do: view

  defp result_view({:ok, {_, {:error, :not_found}}}, _),
    do: %{status: "unavailable", observe: false}

  defp result_view(_, %{retry_errors: true, ref: ref, view: view}) when not is_nil(ref), do: view

  defp result_view(_, state),
    do: %{status: "unavailable", observe: false, summary: state.failure_summary}

  defp apply_view(socket, view, count? \\ true) do
    state = socket.private.sign_in_observer
    view = valid_view(view)
    view = if view, do: Map.put_new(view, :ref, state.ref)
    view = if view, do: Map.merge(Map.take(state.view || %{}, [:dismiss, :retry]), view)
    attempts = state.attempts + if(count?, do: 1, else: 0)
    view = bound_view(view, attempts, state.max_observations)
    state = %{state | view: view, ref: if(view, do: view[:ref]), attempts: attempts}

    socket =
      socket
      |> LiveView.put_private(:sign_in_observer, state)
      |> Component.assign(state.view_key, presentation(view))
      |> schedule(
        :sign_in_observer_timer,
        state.generation,
        :sign_in_tick,
        if(view, do: view[:interval_ms] || 1_000, else: 1_000),
        view != nil and view[:observe] == true
      )

    deliver_completion(socket, state, view)
  end

  defp valid_view(nil), do: nil

  defp valid_view(%{status: status} = view)
       when status in [
              "initializing",
              "pending",
              "confirm",
              "active",
              "connected",
              "disconnected",
              "failed",
              "interrupted",
              "expired",
              "denied",
              "cancelled",
              "unavailable"
            ] do
    interval = view[:interval_ms]

    view =
      Map.put(
        view,
        :interval_ms,
        if(is_integer(interval) and interval > 0, do: interval, else: 1_000)
      )

    if status == "pending", do: view, else: Map.put(view, :challenge, nil)
  end

  defp valid_view(_), do: %{status: "unavailable", observe: false}

  defp bound_view(%{observe: true} = view, attempts, max)
       when is_integer(max) and attempts >= max,
       do:
         Map.merge(view, %{
           status: "expired",
           challenge: nil,
           observe: false,
           summary: "Connection window ended; retry to continue"
         })

  defp bound_view(view, _, _), do: view

  defp presentation(nil), do: nil

  defp presentation(view) do
    view
    |> Map.take([:status, :expires_at, :summary, :retry, :dismiss])
    |> Map.put(
      :challenge,
      public_fields(view[:challenge], [:type, :uri, :code, :value, :expires_at])
    )
    |> Map.put(:confirmation, public_fields(view[:confirmation], [:external_id, :display_name]))
    |> Map.put(
      :completion,
      public_fields(view[:completion], [:kind, :id, :name, :runtime_pending])
    )
  end

  defp public_fields(value, keys) when is_map(value), do: Map.take(value, keys)
  defp public_fields(_, _), do: nil

  defp deliver_completion(socket, %{completed: false} = state, %{completion: receipt})
       when is_map(receipt) do
    socket = LiveView.put_private(socket, :sign_in_observer, %{state | completed: true})
    state.on_complete.(socket, receipt)
  end

  defp deliver_completion(socket, _, _), do: socket

  @doc "Detaches observation and cancels only implementations declaring cancellable dismissal."
  def dismiss(socket) do
    case socket.private[:sign_in_observer] do
      %{view_key: key} = state ->
        cancel_abandoned(state.dispatch, state.view)

        socket
        |> stop(:sign_in_observer_timer)
        |> LiveView.put_private(:sign_in_observer, nil)
        |> Component.assign(key, nil)

      _ ->
        socket
    end
  end

  defp discard_stale(socket, {:ok, {dispatch, {:ok, %{ref: ref} = view}}}) do
    current = socket.private[:sign_in_observer]
    if current == nil or current.ref != ref, do: cancel_abandoned(dispatch, view)
  end

  defp discard_stale(_, _), do: :ok

  defp cancel_abandoned(dispatch, %{ref: ref, dismiss: :cancel}) when not is_nil(ref) do
    Task.Supervisor.start_child(Zaq.TaskSupervisor, fn -> dispatch.({:cancel, ref}) end)
  end

  defp cancel_abandoned(_, _), do: :ok

  @spec schedule(LiveView.Socket.t(), atom(), term(), atom(), pos_integer(), boolean()) ::
          LiveView.Socket.t()
  defp schedule(socket, key, identity, event, interval_ms, active?) do
    if active? do
      case socket.private[key] do
        %{identity: ^identity, event: ^event, interval_ms: ^interval_ms} -> socket
        _ -> start_timer(stop(socket, key), key, identity, event, interval_ms)
      end
    else
      stop(socket, key)
    end
  end

  @spec consume(LiveView.Socket.t(), atom(), term(), reference()) ::
          {:ok, LiveView.Socket.t()} | :stale
  defp consume(socket, key, identity, generation) do
    case socket.private[key] do
      %{identity: ^identity, generation: ^generation} -> {:ok, stop(socket, key)}
      _ -> :stale
    end
  end

  @spec stop(LiveView.Socket.t(), atom()) :: LiveView.Socket.t()
  defp stop(socket, key) do
    if timer = socket.private[key], do: Process.cancel_timer(timer.timer_ref)
    LiveView.put_private(socket, key, nil)
  end

  defp start_timer(socket, key, identity, event, interval_ms) do
    generation = make_ref()
    timer = Process.send_after(self(), {event, identity, generation}, interval_ms)

    LiveView.put_private(socket, key, %{
      identity: identity,
      generation: generation,
      timer_ref: timer,
      event: event,
      interval_ms: interval_ms
    })
  end
end
