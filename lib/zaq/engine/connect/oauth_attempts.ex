defmodule Zaq.Engine.Connect.OAuthAttempts do
  @moduledoc """
  One-use OAuth attempts, never browser-selected owners or configuration.

  Self-service Person starts are authenticated and session-bound by
  `Zaq.Engine.PeopleCredentials`.
  `start_global_configuration/3` is an explicit trusted admin operation: a candidate exists only encrypted in an attempt until completed canonical
  configuration/global-grant save. Neither start authenticates its caller.

  Attempts expire after 600 seconds (exclusive). Claim commits and erases stored PKCE
  and candidate material before network IO. Every failure consumes the claimed attempt;
  a new start is required. Finalization rechecks configuration, literal active identity,
  policy, redirect and expiry under the canonical credential lock. Existing grants and
  notification jobs change atomically only after successful exchange. Calls must not be
  wrapped in caller transactions. PersonLifecycle cancels attempts on merge/deletion
  and reconciles expired rows, retaining live claims. Validation rechecks the persisted attempt under
  the credential lock, so cancellation wins over an in-memory claimed candidate.

  Trusted `opts[:now]` accepts a timestamp or zero-argument clock (UTC now by default)
  and is re-evaluated before final persistence. `config:` uses the shared config seam for the
  existing provider HTTP and encryption dependencies. None of these opts is browser input.
  """
  import Ecto.Query
  alias Zaq.Accounts.{PeopleAuth, PeoplePermissions, Person}
  alias Zaq.Engine.Connect.{Credential, Mutations, OAuth, OAuthAttempt, OAuthState, Snapshot}
  alias Zaq.Repo
  alias Zaq.System.SecretConfig
  alias Zaq.Utils.DateUtils

  @ttl 600
  @type result :: {:ok, map()} | {:error, atom()}

  @doc "Persists a session-bound Person attempt inside the caller's authentication transaction."
  @spec prepare_person(Person.t(), Ecto.UUID.t(), pos_integer(), keyword()) :: result()
  def prepare_person(person, session_id, credential_id, opts \\ [])

  def prepare_person(
        %Person{id: id, __meta__: %{state: :loaded}},
        session_id,
        credential_id,
        opts
      )
      when is_integer(id) and id > 0 and is_binary(session_id) and is_integer(credential_id) and
             credential_id > 0 do
    if Repo.in_transaction?() do
      credential = lock_credential(credential_id)
      ensure(active_person?(id), :unauthorized)
      ensure(eligible?(credential), :not_found)
      {:ok, persist_attempt(credential, "person", id, session_id, nil, opts)}
    else
      {:error, :transaction_required}
    end
  end

  def prepare_person(_, _, _, _), do: {:error, :unauthorized}

  @doc "Performs provider authorization after a prepared attempt has committed."
  @spec authorize_prepared({OAuthAttempt.t(), Credential.t(), map()}, keyword()) :: result()
  def authorize_prepared({%OAuthAttempt{} = attempt, %Credential{} = credential, binding}, opts) do
    authorize(attempt, credential, OAuthState.sign(%{"attempt_id" => attempt.id}), binding, opts)
  end

  def authorize_prepared(_, _), do: {:error, :invalid_attempt}

  @doc "Stages immutable admin configuration; nil creates only after successful OAuth exchange."
  @spec start_global_configuration(Credential.t() | integer() | nil, map(), keyword()) :: result()
  def start_global_configuration(ref, attrs, opts \\ []) do
    start(
      fn ->
        candidate = unwrap(Mutations.prepare_oauth_configuration(ref, attrs))
        persist_attempt(candidate, "org", nil, nil, configuration_attrs(candidate), opts)
      end,
      opts
    )
  end

  @doc "Verifies and consumes opaque signed state, then exchanges and canonically finalizes."
  @spec finalize_callback(String.t(), map(), keyword()) :: result()
  def finalize_callback(provider, params, opts \\ [])

  def finalize_callback(provider, %{"state" => state} = params, opts)
      when is_binary(provider) and is_binary(state) do
    with :ok <- outside_transaction(),
         {:ok, %{"attempt_id" => id} = payload} when map_size(payload) == 1 <-
           OAuthState.verify(state),
         true <- is_binary(id),
         {:ok, attempt} <- claim(id, opts),
         {:ok, credential} <- validate(attempt, provider, opts),
         false <- Map.has_key?(params, "error"),
         code when is_binary(code) and byte_size(code) > 0 <- Map.get(params, "code"),
         {:ok, material} <- exchange(credential, code, attempt, opts) do
      complete(attempt, provider, material, opts)
    else
      {:error, :oauth_failed} = error -> error
      {:error, :transaction_not_allowed} = error -> error
      _ -> {:error, :invalid_attempt}
    end
  end

  def finalize_callback(_, _, _), do: {:error, :invalid_attempt}

  defp start(operation, opts) do
    with :ok <- outside_transaction(),
         {:ok, {attempt, credential, binding}} <- Repo.transaction(operation) do
      state = OAuthState.sign(%{"attempt_id" => attempt.id})
      authorize(attempt, credential, state, binding, opts)
    end
  end

  defp authorize(attempt, credential, state, binding, opts) do
    case safe_provider(fn -> OAuth.authorize_attempt(credential, state, binding, opts) end) do
      {:ok, url} when is_binary(url) ->
        {:ok, %{authorize_url: url}}

      _ ->
        claim(attempt.id, opts)
        {:error, :oauth_failed}
    end
  end

  defp persist_attempt(credential, owner_type, owner_id, session_id, candidate, opts) do
    binding = OAuth.prepare_attempt(credential)
    ensure(valid_redirect?(binding.redirect_uri), :invalid_configuration)

    attempt =
      %OAuthAttempt{}
      |> OAuthAttempt.changeset(%{
        id: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
        credential_id: credential.id,
        owner_type: owner_type,
        owner_id: owner_id,
        session_id: session_id,
        provider: credential.provider,
        config_fingerprint: fingerprint(credential.id),
        redirect_uri: binding.redirect_uri,
        pkce_verifier: encrypt(binding.pkce["code_verifier"], opts),
        candidate_config: encrypt(if(candidate, do: Jason.encode!(candidate)), opts),
        expires_at: DateTime.add(now(opts), @ttl)
      })
      |> Repo.insert(log: false)
      |> unwrap_insert()

    {attempt, credential, binding}
  end

  defp claim(id, opts) do
    Repo.transaction(fn ->
      attempt =
        Repo.one(from(a in OAuthAttempt, where: a.id == ^id, lock: "FOR UPDATE"), log: false)

      ensure(attempt != nil and is_nil(attempt.claimed_at), :invalid_attempt)

      attempt
      |> OAuthAttempt.changeset(%{
        claimed_at: now(opts),
        pkce_verifier: nil,
        candidate_config: nil
      })
      |> Ecto.Changeset.force_change(:pkce_verifier, nil)
      |> Ecto.Changeset.force_change(:candidate_config, nil)
      |> Repo.update(log: false)
      |> unwrap_insert()

      attempt
    end)
  end

  defp validate(attempt, provider, opts),
    do: Repo.transaction(fn -> validate_locked(attempt, provider, opts) end)

  defp validate_locked(attempt, provider, opts) do
    current = if attempt.credential_id, do: lock_credential(attempt.credential_id)
    # Lifecycle cancellation deletes even claimed attempts. Lock after configuration
    # so a callback holding an in-memory candidate cannot outlive cancellation.
    persisted =
      Repo.one(
        from a in OAuthAttempt, where: a.id == ^attempt.id, lock: "FOR UPDATE", select: a.id
      )

    ensure(persisted != nil, :invalid_attempt)
    ensure(DateTime.compare(attempt.expires_at, now(opts)) == :gt, :invalid_attempt)
    ensure(attempt.provider == provider, :invalid_attempt)

    ensure(
      is_binary(attempt.pkce_verifier) and byte_size(attempt.pkce_verifier) > 0,
      :invalid_attempt
    )

    ensure(attempt.config_fingerprint == fingerprint(attempt.credential_id), :invalid_attempt)
    credential = candidate(attempt, current)
    ensure(credential.provider == provider and credential.auth_kind == "oauth2", :invalid_attempt)
    ensure(attempt.redirect_uri == OAuth.redirect_uri_for(credential), :invalid_attempt)

    if attempt.owner_type == "person" do
      ensure(active_person?(attempt.owner_id) and eligible?(credential), :invalid_attempt)
      validate_bound_session(attempt, opts)
    end

    credential
  end

  defp candidate(%{owner_type: "person"}, current), do: current

  defp candidate(attempt, _current) do
    with value when is_binary(value) <- attempt.candidate_config,
         {:ok, attrs} <- Jason.decode(value),
         changeset = Credential.changeset(%Credential{}, attrs),
         true <- changeset.valid? do
      Ecto.Changeset.apply_changes(changeset)
    else
      _ -> Repo.rollback(:invalid_attempt)
    end
  end

  defp exchange(credential, code, attempt, opts) do
    case safe_provider(fn -> OAuth.exchange_attempt(credential, code, attempt, opts) end) do
      {:ok, payload} when is_map(payload) ->
        {:ok, token_material(payload)}

      _ ->
        {:error, :oauth_failed}
    end
  end

  defp token_material(payload) do
    Enum.reduce([:access_token, :refresh_token, :expires_at, :metadata], %{}, fn key, acc ->
      value = Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
      if is_nil(value), do: acc, else: Map.put(acc, key, value)
    end)
  end

  defp complete(attempt, provider, material, opts) do
    case Repo.transaction(fn ->
           credential = validate_locked(attempt, provider, opts)

           result =
             unwrap(replace(attempt, credential, material, Keyword.put(opts, :now, now(opts))))

           %{credential_id: result.credential_id, status: "active"}
         end) do
      {:ok, _} = ok -> ok
      _ -> {:error, :invalid_attempt}
    end
  end

  defp replace(%{owner_type: "person", owner_id: id}, credential, material, opts),
    do: Mutations.replace_credential_grant(credential, {:person, id}, material, opts)

  defp replace(attempt, credential, material, opts),
    do:
      Mutations.save_credential_configuration(
        attempt.credential_id,
        configuration_attrs(credential),
        {:replace, material},
        opts
      )

  defp configuration_attrs(credential) do
    credential
    |> Map.from_struct()
    |> Map.drop([:__meta__, :id, :inserted_at, :updated_at, :grants])
    |> Map.reject(fn {_, value} -> is_nil(value) end)
  end

  # Hash the actual stored administrative fields, including ciphertext digests. No
  # timestamp revision: same-second edits and unreadable/corrupt ciphertext differ.
  defp fingerprint(nil), do: :crypto.hash(:sha256, "new-credential")

  defp fingerprint(id) do
    Snapshot.credential(id, timestamps: false)
  end

  defp lock_credential(id),
    do:
      Repo.one(from(c in Credential, where: c.id == ^id, lock: "FOR UPDATE"), log: false) ||
        Repo.rollback(:not_found)

  defp active_person?(id),
    do: Repo.exists?(from p in Person, where: p.id == ^id and p.status == "active")

  defp eligible?(c),
    do:
      c.auth_kind == "oauth2" and c.secret_binding == :grant and
        c.personal_credential_policy in [:optional, :required]

  defp validate_bound_session(%{session_id: nil}, _opts), do: :ok

  defp validate_bound_session(attempt, opts) do
    with {:ok, auth} <- PeopleAuth.revalidate_session(attempt.owner_id, attempt.session_id, opts),
         true <- PeoplePermissions.allowed?(auth.person, [:access_profile, :manage_credentials]) do
      :ok
    else
      _ -> Repo.rollback(:invalid_attempt)
    end
  end

  defp valid_redirect?(url) do
    uri = URI.parse(url)

    uri.scheme in ["http", "https"] and is_binary(uri.host) and is_nil(uri.userinfo) and
      is_nil(uri.query) and is_nil(uri.fragment)
  end

  defp encrypt(nil, _), do: nil

  defp encrypt(value, opts) do
    case SecretConfig.encrypt(value, opts) do
      {:ok, value} -> value
      _ -> Repo.rollback(:encryption_failed)
    end
  end

  defp safe_provider(fun) do
    fun.()
  rescue
    _ -> {:error, :oauth_failed}
  catch
    _, _ -> {:error, :oauth_failed}
  end

  defp now(opts) do
    value = DateUtils.now(opts)

    %{value | microsecond: {elem(value.microsecond, 0), 6}}
  end

  defp outside_transaction,
    do: if(Repo.in_transaction?(), do: {:error, :transaction_not_allowed}, else: :ok)

  defp ensure(true, _), do: :ok
  defp ensure(false, reason), do: Repo.rollback(reason)
  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: Repo.rollback(reason)
  defp unwrap_insert({:ok, value}), do: value
  defp unwrap_insert({:error, _}), do: Repo.rollback(:invalid_attempt)
end
