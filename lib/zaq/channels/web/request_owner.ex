defmodule Zaq.Channels.Web.RequestOwner do
  @moduledoc """
  Temporary widget transport owner for one accepted message.

  Subscribes before dispatch and serializes create/update/terminal delivery. Only
  an unpredictable PubSub topic in a Delivery snapshot crosses role hops; cluster
  PubSub carries replies back to this owner on the ingress Channels node. Neither
  its PID nor the local dispatch function enters canonical or persisted metadata.
  Timeout removes the live subscriber but does not cancel accepted Engine work.
  This is best-effort delivery, not durable replay or an exactly-once guarantee.
  """

  use GenServer, restart: :temporary

  alias Zaq.Channels.Web.{Delivery, Response}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Returns the internal serializable destination for canonical role propagation."
  def delivery(pid), do: GenServer.call(pid, :delivery)

  @doc "Starts dispatch and returns async acceptance or awaits one sync terminal."
  def run(pid, dispatch), do: GenServer.call(pid, {:run, dispatch}, :infinity)

  @impl true
  def init(opts) do
    delivery = Keyword.fetch!(opts, :delivery)

    {:ok, internal} =
      Delivery.new(%{
        consumer: :widget,
        channel_config_id: delivery.channel_config_id,
        topic: "web-request:#{Ecto.UUID.generate()}",
        events: Map.new([:status, :message_edit, :message_complete, :message_failed], &{&1, &1})
      })

    :ok = Phoenix.PubSub.subscribe(Zaq.PubSub, internal.topic)

    {:ok,
     %{
       delivery: delivery,
       internal: internal,
       mode: Keyword.fetch!(opts, :mode),
       request_id: Keyword.fetch!(opts, :request_id),
       conversation_id: Keyword.fetch!(opts, :conversation_id),
       created: Keyword.get(opts, :created, false),
       assistant_id: Ecto.UUID.generate(),
       timeout: Keyword.fetch!(opts, :timeout),
       waiter: nil,
       worker: nil,
       started: false
     }}
  end

  @impl true
  def handle_call(:delivery, _from, state), do: {:reply, state.internal, state}

  def handle_call({:run, dispatch}, from, %{started: false} = state) do
    task = Task.Supervisor.async_nolink(Zaq.TaskSupervisor, dispatch)
    Process.send_after(self(), :timeout, state.timeout)
    state = %{state | worker: task.ref, started: true}

    if state.mode == :sync do
      {:noreply, %{state | waiter: from}}
    else
      emit(state, response(state, :typing, %{active: true}))
      emit(state, response(state, :message_create, %{body: ""}))
      type = if state.created, do: :conversation_created, else: :status
      {:reply, {:ok, response(state, type, %{accepted: true, created: state.created})}, state}
    end
  end

  def handle_call({:run, _dispatch}, _from, state),
    do: {:reply, {:error, :already_started}, state}

  @impl true
  def handle_info({:web_response, _event, %Response{type: type} = incoming}, state)
      when type in [:message_complete, :message_failed] do
    finish(state, response(state, type, Map.put(incoming.payload, :created, state.created)))
  end

  def handle_info({:web_response, _event, %Response{type: :message_edit} = incoming}, state) do
    if state.mode == :async,
      do: emit(state, response(state, :message_edit, Map.take(incoming.payload, [:body])))

    {:noreply, state}
  end

  def handle_info({:web_response, _event, %Response{type: :status} = incoming}, state) do
    if state.mode == :async do
      stage = Map.get(incoming.payload, :stage)

      emit(
        state,
        response(state, :message_step, %{
          kind: :activity,
          state: :running,
          step_id: Ecto.UUID.generate(),
          label: activity_label(stage)
        })
      )
    end

    {:noreply, state}
  end

  def handle_info({ref, {:error, _reason}}, %{worker: ref} = state),
    do: finish(state, response(state, :message_failed, %{code: :dispatch_error, error: true}))

  def handle_info({ref, _result}, %{worker: ref} = state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{worker: ref} = state) do
    if reason == :normal,
      do: {:noreply, state},
      else: finish(state, response(state, :message_failed, %{code: :dispatch_error, error: true}))
  end

  def handle_info(:timeout, state),
    do:
      finish(
        state,
        response(state, :error, %{code: :timeout, outcome: :unknown, created: state.created})
      )

  def handle_info(_message, state), do: {:noreply, state}

  defp finish(%{mode: :sync, waiter: waiter} = state, terminal) do
    GenServer.reply(waiter, terminal)
    {:stop, :normal, state}
  end

  defp finish(state, terminal) do
    emit(state, response(state, :typing, %{active: false}))
    emit(state, terminal)
    {:stop, :normal, state}
  end

  defp response(state, type, payload) do
    {:ok, response} =
      Response.new(%{
        request_id: state.request_id,
        conversation_id: state.conversation_id,
        message_id: state.assistant_id,
        type: type,
        payload: payload
      })

    response
  end

  defp emit(state, response) do
    with {:ok, event} <- Delivery.event_name(state.delivery, response.type) do
      Phoenix.PubSub.broadcast(Zaq.PubSub, state.delivery.topic, {:web_response, event, response})
    end
  end

  defp activity_label(:retrieving), do: "Retrieving information"
  defp activity_label(:answering), do: "Preparing answer"
  defp activity_label(_stage), do: "Working"
end
