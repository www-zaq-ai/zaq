defmodule Zaq.TestSupport.WhatsAppFlowTransport do
  @moduledoc """
  Simulated WhatsApp service for full-flow tests. Sessions are volatile; pairing
  credentials use the production storage callback. The recipient mailbox is a
  separate process, so tests assert delivered content rather than send acceptance.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def init(opts), do: {:ok, %{observer: opts[:observer], messages: %{}}}

  def connect(config, opts) do
    parent = Keyword.fetch!(opts, :parent)
    scope = Amarula.Storage.scope(config.storage)
    restored = Amarula.Storage.get(scope, config.profile, :creds, :self)

    {:ok, conn} =
      Agent.start(
        fn ->
          %{config: config, parent: parent, storage: scope, paired?: match?({:ok, _}, restored)}
        end,
        name: {:global, {__MODULE__, config.profile}}
      )

    update =
      if match?({:ok, _}, restored),
        do: %{connection: :open},
        else: %{qr: "fixture-qr:#{config.profile}"}

    send(parent, {:amarula, :connection_update, update})
    GenServer.call(__MODULE__, {:connected, config})
    {:ok, conn}
  end

  def stop(conn, _opts) when is_pid(conn), do: Agent.stop(conn)

  def account_identity(conn) do
    {:ok,
     Agent.get(
       conn,
       &Map.get(&1, :identity, %{
         phone_number: "+15550001",
         display_name: "Support account",
         account_jids: ["15550001@s.whatsapp.net"]
       })
     )}
  end

  def account_jids(_conn), do: {:ok, ["15550001@s.whatsapp.net"]}

  def scan(profile, qr, opts \\ []) do
    {:ok, conn} = resolve_conn(profile: profile)
    state = Agent.get(conn, & &1)
    true = qr == "fixture-qr:#{profile}"
    :ok = Amarula.Storage.put(state.storage, profile, :creds, :self, %{paired: true})
    Agent.update(conn, &Map.put(&1, :paired?, true))
    send(state.parent, {:amarula, :pairing_success, %{jid: "15550001@s.whatsapp.net"}})

    if opts[:reconnecting] do
      Agent.update(conn, &Map.put(&1, :recovering?, true))
      send(state.parent, {:amarula, :error, :xml_stream_end})
      send(state.parent, {:amarula, :connection_update, %{connection: :disconnected}})
    else
      send(state.parent, {:amarula, :connection_update, %{connection: :open}})
    end

    :ok
  end

  def recovery_status(conn),
    do: Agent.get(conn, fn state -> if state[:recovering?], do: :reconnecting, else: :failed end)

  def finish_reconnect(profile) do
    {:ok, conn} = resolve_conn(profile: profile)
    Agent.update(conn, &Map.put(&1, :recovering?, false))
    send(Agent.get(conn, & &1.parent), {:amarula, :connection_update, %{connection: :open}})
    :ok
  end

  def incoming(profile, message) do
    {:ok, conn} = resolve_conn(profile: profile)
    true = Agent.get(conn, & &1.paired?)
    send(Agent.get(conn, & &1.parent), {:amarula, :messages_upsert, %{messages: [message]}})
    :ok
  end

  def resolve_conn(opts) do
    case :global.whereis_name({__MODULE__, Keyword.fetch!(opts, :profile)}) do
      :undefined -> {:error, :not_connected}
      pid -> {:ok, pid}
    end
  end

  def send_text(conn, jid, text, _opts), do: deliver(conn, jid, Ecto.UUID.generate(), text)
  def send_edit(conn, {jid, id, true}, text), do: deliver(conn, jid, id, text)
  def send_chatstate(_conn, _jid, _state), do: :ok

  def mailbox, do: GenServer.call(__MODULE__, :mailbox)

  defp deliver(conn, jid, id, text) do
    true = Agent.get(conn, & &1.paired?)
    profile = Agent.get(conn, & &1.config.profile)
    :ok = GenServer.call(__MODULE__, {:deliver, profile, jid, id, text})
    {:ok, id}
  end

  def handle_call({:connected, config}, _from, state) do
    send(state.observer, {:whatsapp_connected_config, config})
    {:reply, :ok, state}
  end

  def handle_call({:deliver, profile, jid, id, text}, _from, state) do
    messages = Map.put(state.messages, {profile, jid, id}, text)
    send(state.observer, {:whatsapp_recipient_received, profile, jid, id, text})
    {:reply, :ok, %{state | messages: messages}}
  end

  def handle_call(:mailbox, _from, state), do: {:reply, state.messages, state}
end

defmodule Zaq.TestSupport.WhatsAppFlowAdapter do
  @moduledoc "Only injects the external transport; all adapter behavior remains real."
  use Jido.Chat.Adapter

  alias Jido.Chat.WhatsApp.Adapter
  alias Zaq.TestSupport.WhatsAppFlowTransport

  defdelegate channel_type(), to: Adapter
  defdelegate capabilities(), to: Adapter
  defdelegate connection_options(binding, opts), to: Adapter
  defdelegate prepare_connection(opts), to: Adapter
  defdelegate connection_profile(binding), to: Adapter
  defdelegate storage_runtime_spec(opts), to: Adapter

  def authenticate(request, owner_id, opts),
    do:
      Adapter.authenticate(
        request,
        owner_id,
        Keyword.put(opts, :transport, WhatsAppFlowTransport)
      )

  def listener_child_specs(id, opts) do
    ingress = Keyword.fetch!(opts, :ingress) |> Map.put(:transport, WhatsAppFlowTransport)
    Adapter.listener_child_specs(id, Keyword.put(opts, :ingress, ingress))
  end

  defdelegate transform_incoming(message), to: Adapter
  defdelegate fetch_metadata(jid, opts), to: Adapter
  defdelegate open_dm(jid, opts), to: Adapter

  def send_message(jid, text, opts),
    do: Adapter.send_message(jid, text, Keyword.put(opts, :transport, WhatsAppFlowTransport))

  def edit_message(jid, id, text, opts),
    do: Adapter.edit_message(jid, id, text, Keyword.put(opts, :transport, WhatsAppFlowTransport))

  def start_typing(jid, opts),
    do: Adapter.start_typing(jid, Keyword.put(opts, :transport, WhatsAppFlowTransport))
end
