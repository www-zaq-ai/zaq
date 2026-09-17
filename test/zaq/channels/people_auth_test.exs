defmodule Zaq.Channels.PeopleAuthTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.{People, PeoplePermissions, PersonLoginChallenge}
  alias Zaq.Channels.{PeopleAuth, PeopleAuthRateLimiter}
  alias Zaq.Channels.PeopleAuthRateLimiter.Config

  setup do
    {:ok, _} = Zaq.System.save_people_access_config(%{unknown_email_attempt_limit: 1})
    send(Config, :refresh)
    _ = :sys.get_state(Config)
    :ok
  end

  test "unknown consumes failure quota; next eligible request performs zero NodeRouter dispatches" do
    ip = {127, 0, 7, 11}
    {:ok, person} = People.create_person(%{full_name: "Blocked", email: "blocked@example.test"})
    {:ok, _} = PeoplePermissions.grant(:everyone, :access_profile)

    assert {:error, :failed_identification} =
             PeopleAuth.request_challenge("unknown@example.test", ip)

    assert {:error, {:rate_limited, _}} = PeopleAuthRateLimiter.check_identification(ip)
    Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")

    task =
      Task.async(fn ->
        receive do
          :run -> PeopleAuth.request_challenge(person.email, ip)
        end
      end)

    :erlang.trace_pattern({Zaq.NodeRouter, :dispatch, 1}, true, [:local])
    :erlang.trace(task.pid, true, [:call, {:tracer, self()}])
    send(task.pid, :run)
    assert {:error, {:rate_limited, _}} = Task.await(task)
    :erlang.trace_pattern({Zaq.NodeRouter, :dispatch, 1}, false, [:local])
    refute_received {:trace, _, :call, {Zaq.NodeRouter, :dispatch, _}}
    refute_received {:node_router_event, _}
    assert Repo.aggregate(PersonLoginChallenge, :count) == 0
  end

  test "delivery failure does not spend unsuccessful-identification quota" do
    ip = {127, 0, 7, 12}

    {:ok, person} =
      People.create_person(%{full_name: "Failed", email: "delivery-failed@example.test"})

    {:ok, _} = PeoplePermissions.grant(:everyone, :access_profile)
    Repo.delete_all(Zaq.Channels.ChannelConfig)
    assert {:error, :delivery_failed} = PeopleAuth.request_challenge(person.email, ip)
    assert :ok = PeopleAuthRateLimiter.check_identification(ip)
  end

  test "invalid snapshot denies without issuing; corrupt Engine config does not count as identification failure" do
    ip = {127, 0, 7, 13}
    {:ok, person} = People.create_person(%{full_name: "Corrupt", email: "corrupt@example.test"})
    {:ok, _} = PeoplePermissions.grant(:everyone, :access_profile)
    Zaq.System.set_config("people_access.otp_validity_seconds", "broken")
    assert {:error, :request_unavailable} = PeopleAuth.request_challenge(person.email, ip)
    assert :ok = PeopleAuthRateLimiter.check_identification(ip)
    send(Config, :refresh)
    _ = :sys.get_state(Config)
    assert {:error, :rate_limiter_unavailable} = PeopleAuth.request_challenge(person.email, ip)
    assert Repo.aggregate(PersonLoginChallenge, :count) == 0
  end
end
