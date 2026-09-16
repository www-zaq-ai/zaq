defmodule Zaq.TestSupport.ConfidentialAuthPeer do
  @moduledoc false
  use GenServer

  alias Ecto.Adapters.SQL.Sandbox

  alias Zaq.Accounts.{People, PeopleAuth, PeoplePermissions}
  alias Zaq.Engine.Events
  alias Zaq.TestSupport.PeopleAuthPeer

  def start(repo_config, endpoint_config, role) do
    {:ok, _} = Application.ensure_all_started(:plug_crypto)
    Application.put_env(:zaq, ZaqWeb.Endpoint, endpoint_config)

    :ok =
      PeopleAuthPeer.start(repo_config, if(role == :engine, do: [:engine], else: []),
        pool: Sandbox
      )

    {:ok, pid} = GenServer.start(__MODULE__, role, name: __MODULE__)
    pid
  end

  @impl true
  def init(role) do
    if role == :engine do
      :ok = Sandbox.checkout(Zaq.Repo)
      :ok = Sandbox.mode(Zaq.Repo, {:shared, self()})
    end

    :ok = Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    {:ok, %{secret_events: 0, controls: MapSet.new(), waiting: %{}}}
  end

  @impl true
  def handle_call(:issue, _from, state) do
    {:ok, person} = People.create_person(%{full_name: "Remote validation"})
    {:ok, _} = PeoplePermissions.grant(:all_people, :access_profile)
    {:ok, challenge} = PeopleAuth.issue_challenge(person, {192, 0, 2, 201})
    {:reply, {person.id, challenge}, state}
  end

  def handle_call({:await, trace}, from, state) do
    if MapSet.member?(state.controls, trace),
      do: {:reply, %{secret_events: state.secret_events, observed_control: true}, state},
      else: {:noreply, put_in(state.waiting[trace], from)}
  end

  @impl true
  def handle_info({:node_router_event, event}, state) do
    secret? =
      event.opts[:confidential] == true or
        (is_map(event.request) and
           (Map.has_key?(event.request, :code) or Map.has_key?(event.request, :token)))

    state = if secret?, do: %{state | secret_events: state.secret_events + 1}, else: state
    state = %{state | controls: MapSet.put(state.controls, event.trace_id)}

    if from = state.waiting[event.trace_id] do
      GenServer.reply(from, %{secret_events: state.secret_events, observed_control: true})
    end

    {:noreply, %{state | waiting: Map.delete(state.waiting, event.trace_id)}}
  end

  # Secrets never leave the connected peers for the ExUnit controller or its logs.
  def verify_remotely(engine_node) do
    {person_id, challenge} = GenServer.call({__MODULE__, engine_node}, :issue)
    event = auth(%{op: :verify, challenge_id: challenge.challenge_id, code: challenge.code})
    {:ok, %{token: token}} = event.response
    {:ok, %{person: person}} = auth(%{op: :authenticate, token: token}).response
    {:ok, _} = auth(%{op: :revoke, token: token}).response
    denied = auth(%{op: :authenticate, token: token}).response == {:error, :invalid_session}

    %{
      remote_engine: Zaq.NodeRouter.find_node(Zaq.Engine.Supervisor) == engine_node,
      verified_person: person.id == person_id,
      revoked: denied,
      context_preserved:
        event.opts[:confidential] == true and event.actor == %{source: :peer_validation}
    }
  end

  def control do
    event =
      Events.build_and_dispatch_invoke_event(
        %{module: String, function: :upcase, args: ["public-control"]},
        :invoke
      )

    {event.trace_id, event.response == "PUBLIC-CONTROL"}
  end

  def await(trace), do: GenServer.call(__MODULE__, {:await, trace}, 5000)

  defp auth(request),
    do:
      Events.build_and_dispatch_invoke_event(request, :people_auth,
        event_opts: [confidential: true],
        actor: %{source: :peer_validation}
      )
end
