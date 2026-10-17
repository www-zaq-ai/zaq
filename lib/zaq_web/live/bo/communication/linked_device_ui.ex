defmodule ZaqWeb.Live.BO.Communication.LinkedDeviceUI do
  @moduledoc "Owns bounded, generation-tagged pairing polling for the selected BO connector."
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [start_async: 3]
  alias Zaq.{Event, NodeRouter}
  alias ZaqWeb.Live.BO.AI.BOActor

  @doc "Begins adapter authentication without persisting a connector."
  def new(socket) do
    socket = close(socket)
    generation = make_ref()

    socket
    |> assign(:linked_device_modal, %{
      config_id: nil,
      session: nil,
      name: "Link your #{socket.assigns.provider_label} account",
      generation: generation,
      attempts: 0,
      status: %{phase: :pending, summary: "Preparing connection"}
    })
    |> refresh(generation, :begin)
  end

  @doc "Confirms only the active provisional session."
  def confirm(
        %{
          assigns: %{
            linked_device_modal: %{
              config_id: nil,
              generation: generation,
              status: %{phase: :confirm, account: %{external_id: account_id}}
            }
          }
        } = socket
      ),
      do: refresh(socket, generation, {:confirm, account_id})

  def confirm(socket), do: socket

  @doc "Opens one selected connector; previous timers and results become stale."
  def open(socket, config) do
    socket = close(socket)
    generation = make_ref()

    socket
    |> assign(:linked_device_modal, %{
      config_id: config.id,
      name: config.name,
      generation: generation,
      attempts: 0,
      status: %{phase: :pending, summary: "Checking device connection"}
    })
    |> refresh(generation, :status)
  end

  @doc "Clears QR presentation and cancels the next scheduled poll."
  def close(socket) do
    case socket.assigns[:linked_device_modal] do
      %{config_id: nil, session: session} when is_pid(session) ->
        actor = BOActor.build(socket.assigns.current_user)
        provider = socket.assigns.provider

        Task.Supervisor.start_child(Zaq.TaskSupervisor, fn ->
          provisional(%{provider: provider, op: :cancel, session: session}, actor)
        end)

      _ ->
        :ok
    end

    if timer = socket.assigns[:linked_device_timer], do: Process.cancel_timer(timer)
    socket |> assign(:linked_device_timer, nil) |> assign(:linked_device_modal, nil)
  end

  @doc "Retries the current session without discarding a successfully linked account."
  def retry(%{assigns: %{linked_device_modal: %{config_id: nil} = modal}} = socket) do
    if is_pid(modal.session) and not Map.get(modal.status, :session_expired, false) do
      if timer = socket.assigns[:linked_device_timer], do: Process.cancel_timer(timer)
      generation = make_ref()

      socket
      |> assign(:linked_device_timer, nil)
      |> assign(:linked_device_modal, %{
        modal
        | generation: generation,
          attempts: 0,
          status: %{phase: :pending, summary: "Checking the linked account"}
      })
      |> refresh(generation, :retry)
    else
      new(socket)
    end
  end

  def retry(%{assigns: %{linked_device_modal: %{config_id: id}}} = socket) do
    config = Enum.find(socket.assigns.configs, &(&1.id == id and &1.enabled))

    if config do
      socket = close(socket)
      generation = make_ref()

      socket
      |> assign(:linked_device_modal, %{
        config_id: id,
        name: config.name,
        generation: generation,
        attempts: 0,
        status: %{phase: :pending, summary: "Reconnecting device"}
      })
      |> refresh(generation, :retry)
    else
      close(socket)
    end
  end

  def retry(socket), do: socket

  @doc "Only the current modal generation may initiate or accept a poll."
  def refresh(socket, generation, operation \\ :status) do
    case socket.assigns[:linked_device_modal] do
      %{generation: ^generation, config_id: nil} = modal ->
        actor = BOActor.build(socket.assigns.current_user)
        provider = socket.assigns.provider
        owner = self()
        request = authentication_request(provider, modal.session, owner, operation)

        start_async(socket, {:linked_device, generation}, fn ->
          provisional(request, actor)
        end)

      %{generation: ^generation, config_id: id} ->
        provider = socket.assigns.provider
        actor = BOActor.build(socket.assigns.current_user)

        start_async(socket, {:linked_device, generation}, fn ->
          request(provider, id, actor, operation)
        end)

      _ ->
        socket
    end
  end

  defp authentication_request(provider, session, _owner, {:confirm, account_id}),
    do: %{provider: provider, op: :confirm, session: session, account_id: account_id}

  defp authentication_request(provider, session, owner, op),
    do: %{provider: provider, op: op, session: session, owner: owner}

  @doc "Applies current results and bounds polling to three minutes per open/retry."
  def result(socket, generation, result) do
    case socket.assigns[:linked_device_modal] do
      %{generation: ^generation} = modal ->
        status = result_status(result, modal)
        if status[:phase] == :saved, do: send(self(), {:linked_device_saved, status.saved})
        modal = remember_session(modal, status)

        attempts = modal.attempts + 1

        watching = watching_status?(status)

        if timer = socket.assigns[:linked_device_timer], do: Process.cancel_timer(timer)

        status =
          if attempts >= 90 and watching,
            do: %{phase: :expired, summary: "Connection window ended; retry to continue"},
            else: status

        socket =
          assign(socket, :linked_device_modal, %{modal | status: status, attempts: attempts})

        if watching and attempts < 90 do
          assign(
            socket,
            :linked_device_timer,
            Process.send_after(self(), {:linked_device_poll, generation}, 2000)
          )
        else
          assign(socket, :linked_device_timer, nil)
        end

      _ ->
        discard_stale_session(socket, result)
        socket
    end
  end

  defp watching_status?(status),
    do:
      status[:phase] in [:pending, :pairing, :expired, :failed] and
        status[:session_expired] != true

  defp result_status({:ok, {:ok, status}}, _) when is_map(status), do: presentation(status)

  defp result_status({:ok, {:error, :pairing_expired}}, _),
    do: %{
      phase: :expired,
      session_expired: true,
      summary: "Pairing session expired; retry to start a new session"
    }

  defp result_status({:ok, {:error, :save_failed}}, modal),
    do: Map.put(modal.status, :summary, "Could not save this account. Confirm to retry.")

  defp result_status({:ok, {:error, :identity_changed}}, _),
    do: %{
      phase: :failed,
      summary: "The linked account changed. Retry and confirm the account again."
    }

  defp result_status(_, _),
    do: %{phase: :failed, summary: "Device connection could not be checked or restarted"}

  defp presentation(%{phase: :challenge, challenge: %{type: :qr, value: qr}} = status),
    do: status |> Map.put(:phase, :pairing) |> Map.put(:qr, qr)

  defp presentation(%{phase: :authenticated} = status),
    do: Map.put(status, :phase, :confirm)

  defp presentation(%{phase: :saved, receipt: receipt} = status),
    do: Map.put(status, :saved, Map.put(receipt, :runtime_pending, status.runtime_pending))

  defp presentation(status), do: status

  defp remember_session(%{session: session} = modal, status),
    do: %{modal | session: status[:session] || session}

  defp remember_session(modal, _), do: modal

  defp discard_stale_session(
         %{assigns: %{linked_device_modal: %{session: session}}},
         {:ok, {:ok, %{session: session}}}
       ),
       do: :ok

  defp discard_stale_session(socket, {:ok, {:ok, %{session: session}}}) do
    actor = BOActor.build(socket.assigns.current_user)
    provider = socket.assigns.provider

    Task.Supervisor.start_child(Zaq.TaskSupervisor, fn ->
      provisional(%{provider: provider, op: :cancel, session: session}, actor)
    end)
  end

  defp discard_stale_session(_, _), do: :ok

  defp provisional(request, actor) do
    Event.new(request, :channels,
      actor: actor,
      opts: [action: :pair_linked_device, confidential: true]
    )
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end

  defp request(provider, id, actor, :retry) do
    case dispatch(provider, id, actor, :channel_retry_linked_device) do
      :ok -> request(provider, id, actor, :status)
      error -> error
    end
  end

  defp request(provider, id, actor, :status),
    do: dispatch(provider, id, actor, :channel_ingress_status)

  defp dispatch(provider, id, actor, action) do
    Event.new(%{provider: provider, channel_config_id: id}, :channels,
      actor: actor,
      opts: [action: action, confidential: true]
    )
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end
end
