defmodule Zaq.Engine.Connect.DeviceAttempts do
  @moduledoc """
  Connect's device-attempt storage and HTTP boundary. Person preparation requires
  the caller's authenticated transaction; admin start is explicitly trusted. Provider
  IO happens only outside transactions. A temporary DeviceWorker owns polling and
  never resumes a prior attempt. Terminal writes erase transient secrets. Success
  and canonical grant replacement commit together; cancellation wins if committed first.
  """
  import Ecto.Query
  alias Zaq.Engine.Connect.{Credential, DeviceAttempt, DeviceWorker, Mutations}
  alias Zaq.Engine.Connect.OAuth.Binding
  alias Zaq.Engine.Connect.OAuth.Device.Registry
  alias Zaq.Repo
  alias Zaq.System.SecretConfig
  alias Zaq.Utils.DateUtils

  def prepare_person(person, session_id, credential_id, opts \\ []) do
    if Repo.in_transaction?() do
      credential = Binding.lock_credential(credential_id)
      ensure(Binding.active_person?(person.id) and Binding.eligible?(credential), :not_found)
      persist(credential, "person", person.id, session_id, nil, opts)
    else
      {:error, :transaction_required}
    end
  end

  def start_global_configuration(ref, attrs, opts \\ []) do
    with :ok <- outside_transaction(),
         {:ok, prepared} <-
           Repo.transaction(fn ->
             credential = unwrap(Mutations.prepare_oauth_configuration(ref, attrs))

             unwrap(
               persist(credential, "org", nil, nil, Binding.configuration_attrs(credential), opts)
             )
           end) do
      authorize_prepared(prepared, opts)
    end
  end

  def authorize_prepared(%DeviceAttempt{} = attempt, opts) do
    attempt = Repo.get!(DeviceAttempt, attempt.id)
    opts = Keyword.put(opts, :device_http_client, http_client(opts))

    with :ok <- outside_transaction(),
         {:ok, credential} <- validate(attempt, opts),
         {:ok, behaviour} <- behaviour(credential),
         {:ok, status, body} <- request(behaviour.initiate_request(credential), opts),
         {:ok, instructions} <- behaviour.initiate_response(status, body),
         {:ok, initialized} <- initialize(attempt, instructions, opts),
         {:ok, _pid} <-
           DynamicSupervisor.start_child(
             supervisor(opts),
             {DeviceWorker, {initialized.id, opts}}
           ) do
      {:ok, public_status(Repo.get!(DeviceAttempt, initialized.id))}
    else
      _ ->
        terminal(attempt.id, "failed", opts)
        {:error, :oauth_failed}
    end
  rescue
    _ ->
      terminal(attempt.id, "failed", opts)
      {:error, :oauth_failed}
  end

  def status(id, owner, opts \\ []) do
    with :ok <- outside_transaction(),
         {:ok, attempt} <- owned(id, owner),
         {:ok, current} <- validated_status(attempt, opts) do
      {:ok, public_status(current)}
    end
  end

  def cancel(id, owner, opts \\ []) do
    with :ok <- outside_transaction(),
         {:ok, _} <- owned(id, owner),
         {:ok, attempt} <- terminal(id, "cancelled", opts) do
      {:ok, public_status(attempt)}
    end
  end

  @doc "Finds the latest attempt for one authenticated owner/configuration, without resuming it."
  def current(credential_id, owner, opts \\ []) do
    query =
      from a in DeviceAttempt,
        where: a.credential_id == ^credential_id,
        order_by: [desc: a.inserted_at, desc: a.id],
        limit: 1,
        select: a.id

    query =
      case owner do
        :org ->
          where(query, [a], a.owner_type == "org")

        {"person", id, session_id} ->
          where(
            query,
            [a],
            a.owner_type == "person" and a.owner_id == ^id and a.session_id == ^session_id
          )
      end

    case Repo.one(query) do
      nil -> {:ok, nil}
      id -> status(id, owner, opts)
    end
  end

  @doc "Bounded expired-attempt cleanup for Connect's existing maintenance scheduler."
  def reconcile(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    now = DateUtils.now(opts)

    if is_integer(limit) and limit in 1..500 do
      Repo.transaction(fn ->
        rows =
          Repo.all(
            from a in DeviceAttempt,
              where: a.expires_at <= ^now,
              order_by: [a.expires_at, a.id],
              limit: ^limit,
              select: %{id: a.id, credential_id: a.credential_id}
          )

        ids = Enum.map(rows, & &1.id)

        credential_ids =
          rows
          |> Enum.map(& &1.credential_id)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.sort()

        Repo.all(
          from c in Credential,
            where: c.id in ^credential_ids,
            order_by: c.id,
            lock: "FOR UPDATE",
            select: c.id
        )

        locked =
          Repo.all(
            from a in DeviceAttempt,
              where: a.id in ^ids and a.expires_at <= ^now,
              order_by: a.id,
              lock: "FOR UPDATE",
              select: struct(a, [:id])
          )

        Enum.each(locked, &Repo.delete!(Ecto.Changeset.change(&1), log: false))
        length(locked)
      end)
    else
      {:error, :invalid_batch}
    end
  end

  @doc "Binds exactly one temporary worker incarnation to an unused device attempt."
  def attach_worker(id, pid) do
    Repo.transaction(fn ->
      attempt = locked(id)
      ensure(attempt.status == "pending" and is_nil(attempt.worker_pid), :invalid_attempt)

      attempt
      |> DeviceAttempt.changeset(%{worker_pid: :erlang.term_to_binary(pid)})
      |> Repo.update(log: false)
      |> unwrap()
    end)
  end

  @doc "Executes one provider poll for the bound worker, outside database transactions."
  def poll(id, pid, opts) do
    with :ok <- outside_transaction(),
         {:ok, {attempt, credential}} <- prepare_poll(id, pid, opts),
         {:ok, behaviour} <- behaviour(credential),
         {:ok, material} <- Jason.decode(attempt.device_material),
         {:ok, status, body} <- request(behaviour.poll_request(credential, material), opts) do
      case behaviour.poll_response(status, body, attempt.interval) do
        {:pending, interval} when is_integer(interval) and interval in 1..3600 ->
          pending(attempt, interval, opts)

        {:exchange, approval} ->
          exchange(attempt, credential, behaviour.exchange_request(credential, approval), opts)

        {:approved, payload} ->
          complete(attempt, credential, payload, opts)

        {:terminal, status} when status in [:denied, :expired, :failed] ->
          terminal(id, Atom.to_string(status), opts)

        _ ->
          terminal(id, "failed", opts)
      end
    else
      {:error, :expired} -> terminal(id, "expired", opts)
      _ -> terminal(id, "failed", opts)
    end
  rescue
    _ -> terminal(id, "failed", opts)
  end

  defp terminal(id, status, _opts) do
    Repo.transaction(fn ->
      attempt = locked(id)
      if attempt.status == "pending", do: finish(attempt, status), else: attempt
    end)
  end

  defp persist(credential, owner_type, owner_id, session_id, candidate, opts) do
    with {:ok, _} <- behaviour(credential) do
      %DeviceAttempt{}
      |> DeviceAttempt.changeset(%{
        id: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
        credential_id: credential.id,
        owner_type: owner_type,
        owner_id: owner_id,
        session_id: session_id,
        provider: credential.provider,
        config_fingerprint: Binding.fingerprint(credential.id),
        candidate_config: encrypt(if(candidate, do: Jason.encode!(candidate)), opts),
        expires_at: DateTime.add(DateUtils.now(opts), 900)
      })
      |> Repo.insert(log: false)
    end
  end

  defp initialize(attempt, instructions, opts) do
    Repo.transaction(fn ->
      Binding.validate_locked(attempt, attempt.provider, opts)
      ensure(valid_instructions?(instructions), :oauth_failed)
      current = locked(attempt.id)
      ensure(current.status == "pending" and is_nil(current.worker_pid), :invalid_attempt)

      current
      |> DeviceAttempt.changeset(%{
        device_material: encrypt(Jason.encode!(instructions.material), opts),
        user_code: encrypt(instructions.user_code, opts),
        verification_uri: instructions.verification_uri,
        interval: instructions.interval,
        expires_at: DateTime.add(DateUtils.now(opts), instructions.expires_in)
      })
      |> Repo.update(log: false)
      |> unwrap()
    end)
  end

  defp valid_instructions?(i) do
    uri = URI.parse(i.verification_uri)

    valid_uri?(uri) and valid_code?(i.user_code) and is_map(i.material) and
      is_integer(i.interval) and i.interval in 1..3600 and
      is_integer(i.expires_in) and i.expires_in in 1..900
  end

  defp valid_uri?(uri), do: uri.scheme == "https" and is_binary(uri.host) and is_nil(uri.userinfo)
  defp valid_code?(code), do: is_binary(code) and byte_size(code) in 1..4096

  defp validate(attempt, opts),
    do: Repo.transaction(fn -> Binding.validate_locked(attempt, attempt.provider, opts) end)

  defp prepare_poll(id, pid, opts) do
    with %DeviceAttempt{} = attempt <- Repo.get(DeviceAttempt, id),
         true <- DateTime.compare(attempt.expires_at, DateUtils.now(opts)) == :gt do
      Repo.transaction(fn -> poll_binding(attempt, pid, opts) end)
    else
      false -> {:error, :expired}
      _ -> {:error, :invalid_attempt}
    end
  end

  defp poll_binding(attempt, pid, opts) do
    credential = Binding.validate_locked(attempt, attempt.provider, opts)
    current = locked(attempt.id)

    ensure(
      current.status == "pending" and current.worker_pid == :erlang.term_to_binary(pid),
      :invalid_attempt
    )

    {current, credential}
  end

  defp exchange(attempt, credential, request, opts) do
    pid = :erlang.binary_to_term(attempt.worker_pid, [:safe])

    with {:ok, _} <- prepare_poll(attempt.id, pid, opts),
         {:ok, status, body} when status in 200..299 and is_map(body) <- request(request, opts) do
      complete(attempt, credential, body, opts)
    else
      _ -> terminal(attempt.id, "failed", opts)
    end
  end

  defp complete(attempt, credential, payload, opts) do
    {:ok, normalizer} =
      Zaq.Engine.Connect.OAuth.Registry.fetch(credential.metadata["auth_profile"])

    material =
      payload
      |> normalize_expiry(opts)
      |> normalizer.normalize_token_payload()
      |> Binding.token_material()

    case Repo.transaction(fn ->
           current_credential = Binding.validate_locked(attempt, attempt.provider, opts)
           current = locked(attempt.id)

           ensure(
             current.status == "pending" and current.worker_pid == attempt.worker_pid,
             :invalid_attempt
           )

           result = unwrap(Binding.replace(attempt, current_credential, material, opts))
           finish(current, "active", %{result_credential_id: result.credential_id})
         end) do
      {:ok, _} = success -> success
      _ -> terminal(attempt.id, "failed", opts)
    end
  end

  defp normalize_expiry(payload, opts) do
    case payload["expires_in"] do
      seconds when is_integer(seconds) and seconds > 0 ->
        Map.put(payload, :expires_at, DateTime.add(DateUtils.now(opts), seconds))

      _ ->
        payload
    end
  end

  defp pending(attempt, interval, opts) do
    Repo.transaction(fn ->
      Binding.validate_locked(attempt, attempt.provider, opts)
      current = locked(attempt.id)

      if current.status == "pending" do
        current
        |> DeviceAttempt.changeset(%{interval: interval})
        |> Repo.update(log: false)
        |> unwrap()
      else
        current
      end
    end)
  end

  defp owned(id, {"person", person_id, session_id}) when is_binary(id) do
    case Repo.get(DeviceAttempt, id) do
      %{owner_type: "person", owner_id: ^person_id, session_id: ^session_id} = attempt ->
        {:ok, attempt}

      _ ->
        {:error, :not_found}
    end
  end

  defp owned(id, :org) when is_binary(id) do
    case Repo.get(DeviceAttempt, id) do
      %{owner_type: "org"} = attempt -> {:ok, attempt}
      _ -> {:error, :not_found}
    end
  end

  defp owned(_, _), do: {:error, :not_found}

  defp validated_status(%{status: "pending"} = attempt, opts) do
    if DateTime.compare(attempt.expires_at, DateUtils.now(opts)) != :gt do
      terminal(attempt.id, "expired", opts)
    else
      validate_pending_status(attempt, opts)
    end
  end

  defp validated_status(attempt, _opts), do: {:ok, attempt}

  defp validate_pending_status(attempt, opts) do
    case validate(attempt, opts) do
      {:ok, _} -> refresh_status(attempt, opts)
      _ -> terminal(attempt.id, "failed", opts)
    end
  end

  defp refresh_status(%{status: "pending"} = attempt, opts) do
    cond do
      DateTime.compare(attempt.expires_at, DateUtils.now(opts)) != :gt ->
        terminal(attempt.id, "expired", opts)

      is_nil(attempt.worker_pid) ->
        terminal(attempt.id, "interrupted", opts)

      true ->
        pid = :erlang.binary_to_term(attempt.worker_pid, [:safe])

        case worker_alive?(pid) do
          true -> {:ok, attempt}
          false -> terminal(attempt.id, "interrupted", opts)
          _ -> {:error, :unavailable}
        end
    end
  end

  defp refresh_status(attempt, _), do: {:ok, attempt}

  defp worker_alive?(pid) when node(pid) == node(), do: Process.alive?(pid)
  defp worker_alive?(pid), do: :rpc.call(node(pid), Process, :alive?, [pid], 2_000)

  defp public_status(attempt) do
    base = %{attempt_id: attempt.id, status: attempt.status, expires_at: attempt.expires_at}

    case attempt.status do
      "pending" ->
        Map.merge(base, %{
          verification_uri: attempt.verification_uri,
          user_code: attempt.user_code
        })

      "active" ->
        Map.put(base, :credential_id, attempt.result_credential_id)

      _ ->
        base
    end
  end

  defp finish(attempt, status, extra \\ %{}) do
    attempt
    |> DeviceAttempt.changeset(
      Map.merge(extra, %{
        status: status,
        device_material: nil,
        candidate_config: nil,
        user_code: nil
      })
    )
    |> Ecto.Changeset.force_change(:device_material, nil)
    |> Ecto.Changeset.force_change(:candidate_config, nil)
    |> Ecto.Changeset.force_change(:user_code, nil)
    |> Repo.update(log: false)
    |> unwrap()
  end

  defp request(%{url: url} = request, opts) do
    client = http_client(opts)

    request_opts = [
      url: url,
      retry: false,
      redirect: false,
      receive_timeout: 10_000,
      connect_options: [timeout: 5_000],
      headers: [{"accept", "application/json"}]
    ]

    request_opts =
      if request[:json],
        do: Keyword.put(request_opts, :json, request.json),
        else: Keyword.put(request_opts, :form, request.form)

    case client.post(request_opts) do
      {:ok, %{status: status, body: body}} -> {:ok, status, body}
      _ -> {:error, :oauth_failed}
    end
  end

  defp http_client(opts) do
    case Keyword.fetch(opts, :device_http_client) do
      {:ok, client} -> client
      :error -> Zaq.Config.get(:zaq, :connect_oauth_http_client, Req, opts)
    end
  end

  defp behaviour(%Credential{auth_kind: "oauth2", metadata: metadata}),
    do: Registry.fetch(metadata["auth_profile"])

  defp behaviour(_), do: {:error, :unsupported_device_flow}

  defp supervisor(opts),
    do:
      Zaq.Config.get(:zaq, :connect_device_supervisor, Zaq.Engine.Connect.DeviceSupervisor, opts)

  defp locked(id),
    do:
      Repo.one(from a in DeviceAttempt, where: a.id == ^id, lock: "FOR UPDATE") ||
        Repo.rollback(:invalid_attempt)

  defp encrypt(nil, _), do: nil

  defp encrypt(value, opts) do
    case SecretConfig.encrypt(value, opts) do
      {:ok, value} -> value
      _ -> Repo.rollback(:encryption_failed)
    end
  end

  defp outside_transaction,
    do: Binding.outside_transaction()

  defp ensure(true, _), do: :ok
  defp ensure(false, error), do: Repo.rollback(error)
  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, _}), do: Repo.rollback(:invalid_attempt)
end
