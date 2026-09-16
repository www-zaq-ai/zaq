defmodule Zaq.People.AuthRateLimiterTest do
  use Zaq.DataCase, async: false
  alias Zaq.Channels.PeopleAuthRateLimiter, as: Ingress
  alias Zaq.People.AuthRateLimiter

  setup do
    refresh()
    unique = System.unique_integer([:positive])
    %{ip: {0, 0, 0, 0, 0, 0, div(unique, 65_536), rem(unique, 65_536)}, person: unique}
  end

  test "precheck does not consume; only failed identification hits the IP budget", %{ip: ip} do
    assert {:ok, _} = Zaq.System.save_people_access_config(%{unknown_email_attempt_limit: 2})
    refresh()
    for _ <- 1..5, do: assert(:ok = Ingress.check_identification(ip))
    assert :ok = Ingress.record_failed_identification(ip)
    assert :ok = Ingress.check_identification(ip)
    assert :ok = Ingress.record_failed_identification(ip)
    assert {:error, {:rate_limited, retry}} = Ingress.check_identification(ip)
    assert retry > 0 and retry <= 600_000
    assert {:error, {:rate_limited, next}} = Ingress.check_identification(ip)
    assert next <= retry
  end

  test "person and IP sends are independent of failed identification", %{ip: ip, person: person} do
    assert {:ok, _} =
             Zaq.System.save_people_access_config(%{
               otp_send_person_limit: 1,
               otp_send_ip_limit: 2
             })

    assert :ok = AuthRateLimiter.reserve_challenge(person, ip)
    assert {:error, {:rate_limited, _}} = AuthRateLimiter.reserve_challenge(person, ip)
    assert :ok = AuthRateLimiter.reserve_challenge(person + 1, ip)
    assert {:error, {:rate_limited, _}} = AuthRateLimiter.reserve_challenge(person + 2, ip)
    assert :ok = Ingress.check_identification(ip)
  end

  test "current limits apply and window changes select a fresh namespaced bucket", %{ip: ip} do
    assert :ok = Ingress.record_failed_identification(ip)
    assert {:ok, _} = Zaq.System.save_people_access_config(%{unknown_email_attempt_limit: 1})
    refresh()
    assert {:error, {:rate_limited, _}} = Ingress.check_identification(ip)
    assert {:ok, _} = Zaq.System.save_people_access_config(%{unknown_email_window_seconds: 601})
    refresh()
    assert :ok = Ingress.check_identification(ip)
    assert {:ok, _} = Zaq.System.set_config("people_access.otp_max_attempts", "bad")
    refresh()
    assert {:error, :rate_limiter_unavailable} = Ingress.check_identification(ip)

    assert {:error, :rate_limiter_unavailable} =
             Ingress.record_failed_identification(ip)

    assert {:error, {:invalid_people_access_config, _}} = AuthRateLimiter.reserve_challenge(1, ip)
  end

  test "malformed and untrusted IP representations are rejected", %{ip: ip} do
    for invalid <- [nil, "127.0.0.1", {256, 0, 0, 1}, {-1, 0, 0, 1}, {1, 2}, %{}] do
      assert {:error, :invalid_ip} = Ingress.check_identification(invalid)
      assert {:error, :invalid_ip} = Ingress.record_failed_identification(invalid)
      assert {:error, :invalid_ip} = AuthRateLimiter.reserve_challenge(1, invalid)
    end

    assert {:error, :invalid_person} = AuthRateLimiter.reserve_challenge(nil, ip)
  end

  test "missing listener fails closed rather than using only local counters", %{
    ip: ip,
    person: person
  } do
    assert :ok = Supervisor.terminate_child(AuthRateLimiter, AuthRateLimiter.Listener)

    try do
      assert :ok = Ingress.check_identification(ip)
      assert :ok = Ingress.record_failed_identification(ip)

      assert {:error, :rate_limiter_unavailable} = AuthRateLimiter.reserve_challenge(person, ip)
    after
      assert {:ok, _} = Supervisor.restart_child(AuthRateLimiter, AuthRateLimiter.Listener)
    end
  end

  test "listener applies increment-only PubSub messages to the local quota", %{ip: ip} do
    key = {:channels, {:identification, ip}, 600_000}

    :ok =
      Phoenix.PubSub.local_broadcast(
        Zaq.PubSub,
        "zaq:people_auth:identification:v1",
        {:inc, key, 600_000, 10}
      )

    _ = :sys.get_state(Ingress.Listener)
    assert {:error, {:rate_limited, _}} = Ingress.check_identification(ip)
  end

  test "native window expiry restores the failed-identification budget", %{ip: ip} do
    {:ok, _} =
      Zaq.System.save_people_access_config(%{
        unknown_email_attempt_limit: 1,
        unknown_email_window_seconds: 1
      })

    refresh()

    # Hammer's native wall clock is not injectable. Elapsed expiry is the behavior
    # under test; align once, then wait only for its returned native retry deadline.
    receive do
    after
      1_001 - rem(System.system_time(:millisecond), 1_000) -> :ok
    end

    assert :ok = Ingress.record_failed_identification(ip)
    assert {:error, {:rate_limited, retry}} = Ingress.check_identification(ip)

    receive do
    after
      retry + 1 -> :ok
    end

    assert :ok = Ingress.check_identification(ip)
    assert :ok = Ingress.record_failed_identification(ip)
  end

  defp refresh do
    send(Ingress.Config, :refresh)
    _ = :sys.get_state(Ingress.Config)
  end
end
