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
  notification jobs change atomically only after successful exchange. Person callback
  validation locks the authenticated Person/session before credential and attempt rows,
  matching authenticated mutation lock order. Calls must not be
  wrapped in caller transactions. PersonLifecycle cancels attempts on merge/deletion
  and reconciles expired rows, retaining live claims. Validation rechecks the persisted attempt under
  the credential lock, so cancellation wins over an in-memory claimed candidate.

  Trusted `opts[:now]` accepts a timestamp or zero-argument clock (UTC now by default)
  and is re-evaluated before final persistence. `config:` uses the shared config seam for the
  existing provider HTTP and encryption dependencies. None of these opts is browser input.
  """
  import Ecto.Query
  alias Zaq.Accounts.{People, Person}
  alias Zaq.Engine.Connect.{Credential, Mutations, OAuth, OAuthAttempt, OAuthState}
  alias Zaq.Engine.Connect.OAuth.Binding
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
      credential = unwrap(Mutations.prepare_person_oauth_configuration(credential_id))
      ensure(People.get_active_literal_person(id) != nil, :unauthorized)
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

        persist_attempt(
          candidate,
          "org",
          nil,
          nil,
          Credential.oauth_configuration_attrs(candidate),
          opts
        )
      end,
      opts
    )
  end

  @doc "Verifies and consumes opaque signed state, then exchanges and canonically finalizes."
  @spec finalize_callback(String.t(), map(), keyword()) :: result()
  def finalize_callback(provider, params, opts \\ [])

  def finalize_callback(provider, %{"state" => state} = params, opts)
      when is_binary(provider) and is_binary(state) do
    with :ok <- OAuth.ensure_outside_transaction(),
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
    with :ok <- OAuth.ensure_outside_transaction(),
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
        config_fingerprint: Mutations.oauth_configuration_fingerprint(credential.id),
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
    ensure(attempt.provider == provider, :invalid_attempt)
    credential = Binding.validate_locked(configuration_binding(attempt), opts)

    persisted =
      Repo.one(
        from a in OAuthAttempt, where: a.id == ^attempt.id, lock: "FOR UPDATE", select: a.id
      )

    ensure(persisted != nil, :invalid_attempt)
    ensure(DateTime.compare(attempt.expires_at, now(opts)) == :gt, :invalid_attempt)

    ensure(
      is_binary(attempt.pkce_verifier) and byte_size(attempt.pkce_verifier) > 0,
      :invalid_attempt
    )

    ensure(attempt.redirect_uri == OAuth.redirect_uri_for(credential), :invalid_attempt)
    credential
  end

  defp exchange(credential, code, attempt, opts) do
    case safe_provider(fn -> OAuth.exchange_attempt(credential, code, attempt, opts) end) do
      {:ok, payload} when is_map(payload) ->
        {:ok, OAuth.token_material(payload)}

      _ ->
        {:error, :oauth_failed}
    end
  end

  defp complete(attempt, provider, material, opts) do
    case Repo.transaction(fn ->
           credential = validate_locked(attempt, provider, opts)

           result =
             unwrap(
               Binding.replace(
                 configuration_binding(attempt),
                 credential,
                 material,
                 Keyword.put(opts, :now, now(opts))
               )
             )

           %{credential_id: result.credential_id, status: "active"}
         end) do
      {:ok, _} = ok -> ok
      _ -> {:error, :invalid_attempt}
    end
  end

  defp configuration_binding(attempt) do
    owner = if attempt.owner_type == "person", do: {:person, attempt.owner_id}, else: :org

    Binding.new(
      owner,
      attempt.credential_id,
      attempt.session_id,
      attempt.provider,
      attempt.config_fingerprint,
      attempt.candidate_config
    )
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

  defp ensure(true, _), do: :ok
  defp ensure(false, reason), do: Repo.rollback(reason)
  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: Repo.rollback(reason)
  defp unwrap_insert({:ok, value}), do: value
  defp unwrap_insert({:error, _}), do: Repo.rollback(:invalid_attempt)
end
