defmodule Zaq.Accounts.PeopleAuth do
  @moduledoc """
  Canonical People authentication lifecycle on Engine nodes.

  Issuance takes a trusted resolved Person or positive ID and trusted IP tuple.
  It resolves current identity through People, requires active + access_profile,
  reserves send budgets and supersedes unfinished challenges. The returned code
  is for a trusted delivery caller ONLY; public callers receive only challenge_id
  and deadlines. Verification takes the opaque challenge UUID, never a Person ID.
  A fixed 60-second interval from the newest unfinished challenge's insertion
  applies before quotas, including when that challenge has already expired.

  Successful verification consumes the challenge and creates a session in the same
  transaction. Only that response contains the raw session bearer token. Session
  IDs are metadata, not authentication credentials. No public session creation API
  exists. Authentication returns the current Person and digest-free session metadata.

  All mutations lock Person before authentication rows, compatible with group
  merges. Credential lookups use literal owners and cannot transfer through aliases.
  Wrong/malformed guesses commit attempts; persistence errors roll back consumption.
  Revocation is independent of signing configuration and capability grants.

  Config is read per operation; expiry is fixed at issuance, max attempts is current.
  The existing endpoint secret_key_base derives the challenge-bound HMAC key with
  versioned purpose separation. No raw code or bearer token enters an Ecto value,
  authentication row or authentication telemetry. Delivery and public routing are
  separate responsibilities: bearer operations require confidential Engine events;
  V1 notification bodies use the existing notification log persistence. Runtime
  opts resolve clock and signing configuration.
  """
  import Ecto.Query

  alias Plug.Crypto.KeyGenerator
  alias Zaq.Accounts.{People, PeoplePermissions, Person, PersonLoginChallenge, PersonSession}
  alias Zaq.People.AuthRateLimiter
  alias Zaq.Repo

  @otp_purpose "zaq:people-auth:otp-verification:v1"
  @resend_interval_seconds 60
  @session_activity_interval_seconds 60

  @type challenge_descriptor :: %{
          challenge_id: Ecto.UUID.t(),
          expires_at: DateTime.t(),
          resend_available_at: DateTime.t()
        }

  @doc "Issues a replacement challenge; code is returned once for trusted delivery only."
  @spec issue_challenge(Person.t() | integer(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def issue_challenge(person, ip, opts \\ []) do
    with {:ok, config} <- Zaq.System.get_people_access_config(),
         {:ok, key} <- signing_key(opts) do
      clock = Keyword.get(opts, :clock, DateTime)
      transaction(fn -> issue_locked(person, ip, config, key, clock) end)
    end
  end

  @doc "Verifies an opaque challenge and atomically returns one newly created bearer session."
  @spec verify_challenge(term(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify_challenge(challenge_id, code, opts \\ []) do
    with {:ok, id} <- uuid(challenge_id, :invalid_challenge),
         {:ok, config} <- Zaq.System.get_people_access_config(),
         {:ok, key} <- signing_key(opts) do
      clock = Keyword.get(opts, :clock, DateTime)
      transaction(fn -> verify_reference(id, code, config, key, clock) end)
    end
  end

  @doc "Authenticates a bearer token against current identity, grants, expiry and revocation."
  @spec authenticate(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def authenticate(token, opts \\ []) do
    with {:ok, _config} <- Zaq.System.get_people_access_config() do
      clock = Keyword.get(opts, :clock, DateTime)
      session_operation(token, &authenticate_session(&1, &2, clock))
    end
  end

  @doc "Revalidates a trusted session reference without accepting a bearer substitute."
  @spec revalidate_session(pos_integer(), Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def revalidate_session(person_id, session_id, opts \\ []) do
    with {:ok, _config} <- Zaq.System.get_people_access_config(),
         {:ok, id} <- uuid(session_id, :invalid_session) do
      clock = Keyword.get(opts, :clock, DateTime)
      transaction(fn -> revalidate_locked_session(person_id, id, clock) end)
    end
  end

  defp revalidate_locked_session(person_id, session_id, clock) do
    with %Person{} = person <- lock_owner(person_id),
         %PersonSession{} = session <-
           Repo.one(
             from(s in PersonSession,
               where: s.id == ^session_id and s.person_id == ^person.id,
               lock: "FOR UPDATE"
             )
           ) do
      authenticate_session(person, session, clock)
    else
      _ -> {:error, :invalid_session}
    end
  end

  @doc "Revokes a bearer session idempotently, including when ineligible or config is corrupt."
  @spec revoke_session(term()) :: {:ok, map()} | {:error, term()}
  def revoke_session(token) do
    session_operation(token, fn _person, session -> revoke_locked_session(session) end)
  end

  @doc "Revokes a session owned by a trusted Person, idempotently."
  @spec revoke_session(Person.t() | integer(), term()) :: {:ok, map()} | {:error, term()}
  def revoke_session(person, session_id) do
    with {:ok, id} <- uuid(session_id, :invalid_session) do
      transaction(fn -> revoke_owned_session(person, id) end)
    end
  end

  defp revoke_owned_session(person, session_id) do
    with {:ok, current} <- lock_person(person),
         %PersonSession{} = session <-
           Repo.one(
             from s in PersonSession,
               where: s.person_id == ^current.id and s.id == ^session_id,
               lock: "FOR UPDATE"
           ) do
      revoke_locked_session(session)
    else
      _ -> {:error, :not_found}
    end
  end

  defp revoke_locked_session(%{revoked_at: revoked_at} = session) when not is_nil(revoked_at),
    do: {:ok, session_metadata(session)}

  defp revoke_locked_session(session) do
    session
    |> PersonSession.changeset(%{revoked_at: DateTime.utc_now(:second)})
    |> Repo.update()
    |> persisted!()
    |> session_metadata()
    |> then(&{:ok, &1})
  end

  @doc "Lists digest-free session metadata for a trusted Person; this is not a bearer authorization API."
  @spec list_sessions(Person.t() | integer(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_sessions(person, opts \\ []) when is_list(opts) do
    transaction(fn ->
      with {:ok, current} <- lock_person(person) do
        active_only = Keyword.get(opts, :active_only, false)
        now = DateTime.utc_now(:second)

        rows =
          from(s in PersonSession,
            where: s.person_id == ^current.id,
            order_by: [asc: s.inserted_at, asc: s.id]
          )
          |> maybe_active_sessions(active_only, now)
          |> Repo.all()

        {:ok, Enum.map(rows, &session_metadata/1)}
      end
    end)
  end

  defp maybe_active_sessions(query, true, now),
    do: where(query, [s], is_nil(s.revoked_at) and s.expires_at > ^now)

  defp maybe_active_sessions(query, false, _now), do: query

  @doc "Invalidates all unfinished challenges, including expired ones, without loading auth config."
  @spec invalidate_challenges(Person.t() | integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def invalidate_challenges(person) do
    transaction(fn ->
      with {:ok, current} <- lock_person(person) do
        {:ok, invalidate_locked(current.id, DateTime.utc_now(:second))}
      end
    end)
  end

  @doc "Invalidates only the named unfinished challenge; missing/finished rows are idempotent no-ops."
  @spec invalidate_challenge(term()) :: {:ok, non_neg_integer()} | {:error, term()}
  def invalidate_challenge(challenge_id) do
    with {:ok, id} <- uuid(challenge_id, :invalid_challenge) do
      transaction(fn -> invalidate_reference(id) end)
    end
  end

  @doc "Rechecks live challenge eligibility after delivery, returning only a public-safe descriptor."
  @spec challenge_status(term(), keyword()) :: {:ok, challenge_descriptor()} | {:error, term()}
  def challenge_status(challenge_id, opts \\ []) do
    with {:ok, id} <- uuid(challenge_id, :invalid_challenge),
         {:ok, config} <- Zaq.System.get_people_access_config() do
      clock = Keyword.get(opts, :clock, DateTime)

      transaction(fn -> challenge_status_locked(id, config, clock) end)
    end
  end

  defp invalidate_reference(id) do
    case locked_challenge(id) do
      {_person, challenge} -> invalidate_unfinished(challenge)
      nil -> {:ok, 0}
    end
  end

  defp invalidate_unfinished(challenge) do
    if unfinished?(challenge) do
      challenge
      |> PersonLoginChallenge.changeset(%{invalidated_at: DateTime.utc_now(:second)})
      |> Repo.update()
      |> persisted!()

      {:ok, 1}
    else
      {:ok, 0}
    end
  end

  defp challenge_status_locked(id, config, clock) do
    with {person, challenge} <- locked_challenge(id),
         true <- eligible?(person) and unfinished?(challenge),
         true <- DateTime.before?(clock.utc_now(:second), challenge.expires_at),
         true <- challenge.attempt_count < config.otp_max_attempts do
      {:ok, challenge_descriptor(challenge)}
    else
      _ -> {:error, :invalid_challenge}
    end
  end

  defp locked_challenge(id) do
    with person_id when is_integer(person_id) <-
           Repo.one(from c in PersonLoginChallenge, where: c.id == ^id, select: c.person_id),
         %Person{} = person <- lock_owner(person_id),
         %PersonLoginChallenge{} = challenge <-
           Repo.one(from c in PersonLoginChallenge, where: c.id == ^id, lock: "FOR UPDATE") do
      {person, challenge}
    else
      _ -> nil
    end
  end

  @doc "Revokes all sessions for a trusted Person without checking eligibility or auth config."
  @spec revoke_all_sessions(Person.t() | integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def revoke_all_sessions(person) do
    transaction(fn ->
      with {:ok, current} <- lock_person(person) do
        rows =
          Repo.all(
            from s in PersonSession,
              where: s.person_id == ^current.id and is_nil(s.revoked_at),
              order_by: s.id,
              lock: "FOR UPDATE"
          )

        now = DateTime.utc_now(:second)

        Enum.each(
          rows,
          &(&1 |> PersonSession.changeset(%{revoked_at: now}) |> Repo.update() |> persisted!())
        )

        {:ok, length(rows)}
      end
    end)
  end

  defp issue_locked(person, ip, config, key, clock) do
    with {:ok, current} <- lock_person(person),
         true <- eligible?(current),
         now = clock.utc_now(:second),
         :ok <- check_resend(current.id, now),
         :ok <- reserve_challenge(current.id, ip, config) do
      invalidate_locked(current.id, now)
      id = Ecto.UUID.generate()
      code = generate_code()

      row =
        %PersonLoginChallenge{}
        |> PersonLoginChallenge.changeset(%{
          id: id,
          person_id: current.id,
          token_digest: otp_digest(key, id, code),
          expires_at: expiration(now, config.otp_validity_seconds),
          inserted_at: now,
          updated_at: now
        })
        |> Repo.insert()
        |> persisted!()

      {:ok, Map.put(challenge_descriptor(row), :code, code)}
    else
      false -> {:error, :ineligible}
      error -> error
    end
  end

  # Issuance owns budget ordering and uses the same config snapshot as challenge
  # expiry. Reservations are intentionally not refunded after later failures.
  defp reserve_challenge(person_id, ip, config) do
    scale = config.otp_send_window_seconds * 1_000

    with :ok <- AuthRateLimiter.validate_ip(ip),
         :ok <-
           AuthRateLimiter.hit(
             :engine,
             {:send_person, person_id},
             scale,
             config.otp_send_person_limit
           ) do
      AuthRateLimiter.hit(:engine, {:send_ip, ip}, scale, config.otp_send_ip_limit)
    end
  end

  defp verify_reference(id, code, config, key, clock) do
    with {person, challenge} <- locked_challenge(id),
         true <- eligible?(person) do
      verify_locked(challenge, code, config, key, clock.utc_now(:second))
    else
      _ -> {:error, :invalid_challenge}
    end
  end

  defp check_resend(person_id, now) do
    latest =
      Repo.one(
        from c in PersonLoginChallenge,
          where: c.person_id == ^person_id and is_nil(c.consumed_at) and is_nil(c.invalidated_at),
          order_by: [desc: c.inserted_at],
          limit: 1
      )

    retry_after = if latest, do: DateTime.diff(resend_available_at(latest), now), else: 0
    if retry_after > 0, do: {:error, {:resend_limited, retry_after}}, else: :ok
  end

  defp challenge_descriptor(challenge) do
    %{
      challenge_id: challenge.id,
      expires_at: challenge.expires_at,
      resend_available_at: resend_available_at(challenge)
    }
  end

  defp resend_available_at(challenge),
    do: DateTime.add(challenge.inserted_at, @resend_interval_seconds, :second)

  defp authenticate_session(person, session, clock) do
    permissions = PeoplePermissions.effective_permissions(person)
    now = clock.utc_now(:second)

    if person.status == "active" and MapSet.member?(permissions, :access_profile) and
         is_nil(session.revoked_at) and
         DateTime.before?(now, session.expires_at) do
      session = maybe_touch_session(session, now)
      {:ok, %{person: person, permissions: permissions, session: session_metadata(session)}}
    else
      {:error, :invalid_session}
    end
  end

  defp maybe_touch_session(%PersonSession{last_seen_at: nil} = session, now),
    do: write_last_seen(session, now)

  defp maybe_touch_session(%PersonSession{last_seen_at: last_seen_at} = session, now) do
    if not DateTime.before?(now, last_seen_at) and
         DateTime.diff(now, last_seen_at) >= @session_activity_interval_seconds do
      write_last_seen(session, now)
    else
      session
    end
  end

  defp write_last_seen(session, now) do
    session
    |> PersonSession.changeset(%{last_seen_at: now})
    |> Repo.update()
    |> persisted!()
  end

  defp verify_locked(challenge, code, config, key, now) do
    if unfinished?(challenge) and DateTime.before?(now, challenge.expires_at) and
         challenge.attempt_count < config.otp_max_attempts do
      digest = otp_digest(key, challenge.id, normalize_code(code))

      if Plug.Crypto.secure_compare(challenge.token_digest, digest) do
        challenge
        |> PersonLoginChallenge.changeset(%{consumed_at: now})
        |> Repo.update()
        |> persisted!()

        create_session(challenge.person_id, config, now)
      else
        challenge
        |> PersonLoginChallenge.changeset(%{attempt_count: challenge.attempt_count + 1})
        |> Repo.update()
        |> persisted!()

        {:error, :invalid_challenge}
      end
    else
      {:error, :invalid_challenge}
    end
  end

  defp create_session(person_id, config, now) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    session =
      %PersonSession{}
      |> PersonSession.changeset(%{
        person_id: person_id,
        token_digest: :crypto.hash(:sha256, token),
        expires_at: expiration(now, config.session_lifetime_seconds),
        inserted_at: now,
        updated_at: now
      })
      |> Repo.insert()
      |> persisted!()

    {:ok, %{token: token, session: session_metadata(session)}}
  end

  defp session_operation(token, fun) do
    with {:ok, digest} <- session_digest(token) do
      transaction(fn -> locked_session_operation(digest, fun) end)
    end
  end

  defp locked_session_operation(digest, fun) do
    with {id, person_id} <-
           Repo.one(
             from s in PersonSession,
               where: s.token_digest == ^digest,
               select: {s.id, s.person_id}
           ),
         %Person{} = person <- lock_owner(person_id),
         %PersonSession{} = session <-
           Repo.one(from s in PersonSession, where: s.id == ^id, lock: "FOR UPDATE") do
      fun.(person, session)
    else
      _ -> {:error, :invalid_session}
    end
  end

  defp lock_person(%Person{id: id}), do: lock_person(id)

  defp lock_person(id) when is_integer(id) and id > 0 do
    with %Person{id: current_id} <- People.get_person(id),
         %Person{} = current <- lock_owner(current_id) do
      {:ok, current}
    else
      _ -> {:error, :not_found}
    end
  end

  defp lock_person(_person), do: {:error, :not_found}

  defp lock_owner(id), do: Repo.one(from p in Person, where: p.id == ^id, lock: "FOR UPDATE")

  defp eligible?(person),
    do: person.status == "active" and PeoplePermissions.allowed?(person, :access_profile)

  defp unfinished?(challenge),
    do: is_nil(challenge.consumed_at) and is_nil(challenge.invalidated_at)

  defp invalidate_locked(person_id, now) do
    rows =
      Repo.all(
        from c in PersonLoginChallenge,
          where: c.person_id == ^person_id and is_nil(c.consumed_at) and is_nil(c.invalidated_at),
          order_by: c.id,
          lock: "FOR UPDATE"
      )

    Enum.each(
      rows,
      &(&1
        |> PersonLoginChallenge.changeset(%{invalidated_at: now})
        |> Repo.update()
        |> persisted!())
    )

    length(rows)
  end

  defp session_metadata(session),
    do: Map.take(session, [:id, :expires_at, :revoked_at, :last_seen_at, :inserted_at])

  defp signing_key(opts) do
    base =
      Keyword.get_lazy(opts, :secret_key_base, fn ->
        Zaq.Config.get(:zaq, ZaqWeb.Endpoint, [], opts) |> Keyword.get(:secret_key_base)
      end)

    if is_binary(base) and byte_size(base) >= 64,
      do: {:ok, KeyGenerator.generate(base, @otp_purpose, length: 32)},
      else: {:error, :invalid_signing_configuration}
  end

  # Rejection sampling avoids modulo bias across the entire eight-digit space.
  defp generate_code do
    <<value::unsigned-32>> = :crypto.strong_rand_bytes(4)

    if value < 4_200_000_000,
      do: value |> rem(100_000_000) |> Integer.to_string() |> String.pad_leading(8, "0"),
      else: generate_code()
  end

  defp normalize_code(code) when is_binary(code) do
    if String.valid?(code) do
      normalized = String.replace(code, ~r/[\s-]/u, "")
      if Regex.match?(~r/\A[0-9]{8}\z/, normalized), do: normalized, else: "invalid"
    else
      "invalid"
    end
  end

  defp normalize_code(_code), do: "invalid"
  defp otp_digest(key, id, code), do: :crypto.mac(:hmac, :sha256, key, id <> ":" <> code)

  defp session_digest(token) when is_binary(token) and byte_size(token) == 43 do
    case Base.url_decode64(token, padding: false) do
      {:ok, bytes} when byte_size(bytes) == 32 -> {:ok, :crypto.hash(:sha256, token)}
      _ -> {:error, :invalid_session}
    end
  end

  defp session_digest(_token), do: {:error, :invalid_session}

  defp uuid(value, error) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, error}
    end
  end

  defp uuid(_value, error), do: {:error, error}

  defp expiration(now, seconds) do
    case DateTime.from_unix(DateTime.to_unix(now) + seconds, :second) do
      {:ok, expires_at} -> expires_at
      {:error, _reason} -> Repo.rollback(:invalid_expiry)
    end
  end

  defp persisted!({:ok, row}), do: row
  defp persisted!({:error, reason}), do: Repo.rollback(reason)

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
