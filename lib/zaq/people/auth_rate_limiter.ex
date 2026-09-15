defmodule Zaq.People.AuthRateLimiter do
  @moduledoc """
  Shared People authentication counter mechanics and Engine issuance budgets.

  Uses Hammer 7.5's official increment-only Phoenix.PubSub pattern. Counters are
  eventually consistent, not a global atomic quota. New/restarted nodes start empty;
  partitions lose increments and there is no replay or state transfer. Retry times
  are milliseconds until normal window expiry, not an independent cooldown.

  Engine reservations read the current typed People access group. Channels supplies
  locally cached limits to the shared mechanics. Each role has a separate table,
  listener and replication topic, including on combined-role nodes. Keys include the
  scale: changing a window selects another bucket; changing a limit applies to the
  current count. IPs must be trusted address tuples, never forwarded-header strings.
  """
  use Supervisor

  alias Zaq.Channels.PeopleAuthRateLimiter, as: Ingress
  alias Zaq.People.AuthRateLimiter.{Listener, Local}

  @pubsub Zaq.PubSub

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    role = Keyword.get(opts, :role, :engine)
    Supervisor.start_link(__MODULE__, role, name: runtime(role))
  end

  @impl true
  def init(role) do
    listener =
      Supervisor.child_spec(
        {Listener, name: listener(role), local: local(role), pubsub: @pubsub, topic: topic(role)},
        id: listener(role)
      )

    Supervisor.init([local(role), listener], strategy: :one_for_all)
  end

  defp runtime(:engine), do: __MODULE__
  defp runtime(:channels), do: Ingress.Runtime
  defp local(:engine), do: Local
  defp local(:channels), do: Ingress.Local
  defp listener(:engine), do: Listener
  defp listener(:channels), do: Ingress.Listener
  defp topic(:engine), do: "zaq:people_auth:issuance:v1"
  defp topic(:channels), do: "zaq:people_auth:identification:v1"

  @doc """
  Reserves person then IP send budgets for an eligible challenge issuance/resend.
  Reservations are not refunded on later denial or database failure. Hammer counts
  denied hits too; none extend the fixed window. This is not delivery accounting.
  """
  @spec reserve_challenge(term(), term()) :: :ok | {:error, term()}
  def reserve_challenge(person_id, ip) when is_integer(person_id) and person_id > 0 do
    with :ok <- validate_ip(ip),
         {:ok, config} <- Zaq.System.get_people_access_config(),
         scale = config.otp_send_window_seconds * 1_000,
         :ok <- hit(:engine, {:send_person, person_id}, scale, config.otp_send_person_limit) do
      hit(:engine, {:send_ip, ip}, scale, config.otp_send_ip_limit)
    end
  end

  def reserve_challenge(_person_id, _ip), do: {:error, :invalid_person}

  @doc "Validates trusted socket address tuples for either role's counter boundary."
  @spec validate_ip(term()) :: :ok | {:error, :invalid_ip}
  def validate_ip(ip) when is_tuple(ip) and tuple_size(ip) in [4, 8] do
    max = if tuple_size(ip) == 4, do: 255, else: 65_535

    if Enum.all?(Tuple.to_list(ip), &(is_integer(&1) and &1 >= 0 and &1 <= max)),
      do: :ok,
      else: {:error, :invalid_ip}
  end

  def validate_ip(_ip), do: {:error, :invalid_ip}

  @doc "Shared non-consuming counter check with role-local infrastructure and resolved positive limits."
  @spec check(:engine | :channels, term(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  def check(role, scope, scale, limit) do
    available(role, fn ->
      local = local(role)
      key = {role, scope, scale}

      if local.get(key, scale) < limit do
        :ok
      else
        {:error,
         {:rate_limited, max(local.expires_at(key, scale) - System.system_time(:millisecond), 0)}}
      end
    end)
  end

  @doc "Shared role-local counter hit and remote-only increment replication with resolved positive limits."
  @spec hit(:engine | :channels, term(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  def hit(role, scope, scale, limit) do
    available(role, fn ->
      local = local(role)
      key = {role, scope, scale}
      # Adapter broadcast reaches other nodes only, avoiding double local counting.
      with {:ok, {adapter, name, dispatcher}} <- Registry.meta(@pubsub, :pubsub),
           :ok <- adapter.broadcast(name, topic(role), {:inc, key, scale, 1}, dispatcher) do
        local.hit(key, scale, limit) |> hit_result()
      else
        _ -> {:error, :rate_limiter_unavailable}
      end
    end)
  end

  defp available(role, fun) do
    if Process.whereis(listener(role)) && :ets.whereis(local(role)) != :undefined do
      fun.()
    else
      {:error, :rate_limiter_unavailable}
    end
  rescue
    ArgumentError -> {:error, :rate_limiter_unavailable}
  end

  defp hit_result({:allow, _count}), do: :ok
  defp hit_result({:deny, retry_after}), do: {:error, {:rate_limited, retry_after}}
end
