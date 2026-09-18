defmodule Zaq.Engine.Connect.Mutations do
  @moduledoc """
  Atomic canonical Connect configuration and grant mutations for trusted Engine callers.

  Owners are explicit `:org` or `{:person, literal_id}`; these values are not caller
  authentication and must never be sourced directly from browser attributes. All
  operations lock the reloaded credential before the canonical slot, including absent
  slots. Legacy writers do not participate in this protocol.

  Configuration omission retains values. Global `:keep` retains the slot; replacement
  is complete, clears omitted grant material, retains the slot ID and reactivates it.
  Cleanup does not validate auth material or current Person eligibility. Transactions
  compose with outer Repo transactions; secret-free Oban notifications commit with
  writes through `MutationEvents`. No external dispatch occurs in the transaction.
  Management errors are fixed atoms and results contain only allowlisted IDs/status/policy.
  The internal claimed-refresh writer returns a secret-bearing runtime grant only to
  `Connect.Refresh`, whose caller-held locks and snapshot checks precede persistence.

  OAuth attempts may prepare an internal candidate without persisting it. Completion
  still uses the same atomic save and global usability validation below.
  """

  import Ecto.Query
  alias Ecto.Changeset
  alias Zaq.Accounts.Person
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant, MutationEvents}
  alias Zaq.Repo
  alias Zaq.System.SecretConfig
  alias Zaq.Utils.DateUtils

  @secrets ~w(api_key access_token refresh_token private_key)a
  @config_secrets ~w(api_key private_key client_secret)a
  @auth_config ~w(provider auth_kind request_format scopes issuer key_id client_id client_secret metadata)a
  @config_fields ~w(name provider auth_kind user_level personal_credential_policy secret_binding request_format metadata client_id client_secret scopes issuer private_key key_id api_key expires_at)a

  @type owner :: :org | {:person, pos_integer()}
  @type credential_ref :: Credential.t() | integer()
  @type result :: {:ok, map()} | {:error, atom()}

  @doc "Atomically saves completed configuration; omitted global instruction means keep."
  @spec save_credential_configuration(
          credential_ref() | nil,
          map(),
          :keep | {:replace, map()},
          keyword()
        ) :: result()
  def save_credential_configuration(ref, attrs, global \\ :keep, opts \\ []) do
    transact(fn ->
      attrs = normalize_attrs(attrs, @config_fields, :invalid_configuration)
      validate_instruction(global)
      original = if is_nil(ref), do: %Credential{}, else: lock_credential(ref)
      candidate = configuration_candidate(original, attrs)

      validate_auth_change(original, Changeset.apply_changes(candidate), global)
      encrypted_attrs = encrypt_attrs(attrs, @config_secrets, opts, :invalid_configuration)
      credential = persist_configuration(original, encrypted_attrs)
      grant = global_grant(credential, global, opts)

      ensure(
        credential.personal_credential_policy == :required or
          usable?(grant, credential, now(opts)),
        :global_grant_unusable
      )

      %{
        credential_id: credential.id,
        personal_credential_policy: credential.personal_credential_policy,
        global_grant: if(grant, do: grant_result(grant))
      }
    end)
  end

  @doc """
  Internal trusted admin setup validation. Returns a secret-bearing candidate only to
  OAuthAttempts for encrypted transient storage, never to transports. No write occurs;
  finalization must use `save_credential_configuration/4` with completed global material.
  """
  @spec prepare_oauth_configuration(credential_ref() | nil, map()) ::
          {:ok, Credential.t()} | {:error, atom()}
  def prepare_oauth_configuration(ref, attrs) do
    transact(fn ->
      attrs = normalize_attrs(attrs, @config_fields, :invalid_configuration)
      original = if is_nil(ref), do: %Credential{}, else: lock_credential(ref)
      candidate = original |> configuration_candidate(attrs) |> Changeset.apply_changes()

      ensure(
        candidate.auth_kind == "oauth2" and candidate.secret_binding == :grant,
        :invalid_configuration
      )

      ensure(
        Enum.all?(Map.take(attrs, @config_secrets), fn {_, value} -> present?(value) end),
        :invalid_configuration
      )

      validate_auth_change(original, candidate, {:replace, %{}})
      candidate
    end)
  end

  defp configuration_candidate(original, attrs) do
    candidate = Credential.changeset(original, attrs)
    ensure(candidate.valid?, :invalid_configuration)
    validate_metadata(Changeset.apply_changes(candidate))

    ensure(
      Enum.all?([:user_level, :scopes], &(not is_nil(Changeset.get_field(candidate, &1)))),
      :invalid_configuration
    )

    candidate
  end

  @doc "Replaces complete grant material in the credential/owner slot and reactivates it."
  @spec replace_credential_grant(credential_ref(), owner(), map(), keyword()) :: result()
  def replace_credential_grant(ref, owner, material, opts \\ []) do
    transact(fn ->
      credential = lock_credential(ref)
      owner = validate_owner(owner)
      grant = lock_slot(credential.id, owner)
      replace(credential, owner, grant, material, opts) |> grant_result()
    end)
  end

  @doc "Retains a revoked slot while clearing all secret material, even for stale People."
  @spec revoke_credential_grant(credential_ref(), owner()) :: result()
  def revoke_credential_grant(ref, owner), do: cleanup(ref, owner, :revoke)

  @doc "Deletes the slot, restoring absence semantics; repeated removal succeeds."
  @spec remove_credential_grant(credential_ref(), owner()) :: result()
  def remove_credential_grant(ref, owner), do: cleanup(ref, owner, :remove)

  @doc "Internal claimed-refresh writer; caller holds credential/grant locks and verifies its snapshot."
  @spec persist_refreshed_grant(Grant.t(), Credential.t(), map(), keyword()) ::
          {:ok, Grant.t()} | {:error, atom()}
  def persist_refreshed_grant(grant, credential, material, opts) do
    transact(fn ->
      validate_current_person(
        if grant.owner_type == "person", do: {:person, grant.owner_id}, else: :org
      )

      material = normalize_attrs(material, material_fields("oauth2"), :invalid_material)
      attrs = Map.put(material, :status, "active")
      changeset = Grant.credential_changeset(grant, credential, attrs)
      ensure(changeset.valid?, :invalid_material)

      ensure(
        usable?(Changeset.apply_changes(changeset), credential, now(opts)),
        :invalid_material
      )

      encrypted =
        encrypt_attrs(material, [:access_token, :refresh_token], opts, :invalid_material)

      changeset =
        Enum.reduce(Map.take(encrypted, [:access_token, :refresh_token]), changeset, fn {key,
                                                                                         value},
                                                                                        acc ->
          Changeset.force_change(acc, key, value)
        end)

      changeset
      |> MutationEvents.persist("grant_tokens_updated")
      |> unwrap(:mutation_event_enqueue_failed)
      |> Repo.reload!()
    end)
  end

  defp transact(fun), do: Repo.transaction(fun)

  defp lock_credential(%Credential{id: id}), do: lock_credential(id)

  defp lock_credential(id) when is_integer(id) do
    Repo.one(from c in Credential, where: c.id == ^id, lock: "FOR UPDATE") ||
      Repo.rollback(:not_found)
  end

  defp lock_credential(_), do: Repo.rollback(:not_found)

  defp validate_owner(:org), do: :org
  defp validate_owner({:person, id} = owner) when is_integer(id) and id > 0, do: owner
  defp validate_owner(_), do: Repo.rollback(:invalid_owner)

  defp lock_slot(id, owner) do
    query =
      from g in Grant,
        where: g.credential_id == ^id and g.resource_type == "connect_credential",
        lock: "FOR UPDATE"

    query =
      case owner do
        :org ->
          where(query, [g], g.owner_type == "org" and is_nil(g.owner_id))

        {:person, person_id} ->
          where(query, [g], g.owner_type == "person" and g.owner_id == ^person_id)
      end

    Repo.one(query)
  end

  defp validate_instruction(:keep), do: :ok
  defp validate_instruction({:replace, material}) when is_map(material), do: :ok
  defp validate_instruction(_), do: Repo.rollback(:invalid_instruction)

  defp persist_configuration(%Credential{id: nil}, attrs) do
    unwrap(Connect.create_credential(attrs), :invalid_configuration)
  end

  defp persist_configuration(credential, attrs) do
    unwrap(Connect.update_credential(credential, attrs), :invalid_configuration)
  end

  defp global_grant(credential, :keep, _opts), do: lock_slot(credential.id, :org)

  defp global_grant(credential, {:replace, material}, opts) do
    replace(credential, :org, lock_slot(credential.id, :org), material, opts)
  end

  defp validate_auth_change(%Credential{id: nil}, _candidate, _global), do: :ok

  defp validate_auth_change(original, candidate, global) do
    if Map.take(original, @auth_config) != Map.take(candidate, @auth_config) do
      query =
        from g in Grant,
          where:
            g.credential_id == ^original.id and g.resource_type == "connect_credential" and
              g.status == "active",
          order_by: g.id,
          lock: "FOR UPDATE"

      incompatible =
        Enum.any?(Repo.all(query), fn grant ->
          not (match?({:replace, _}, global) and grant.owner_type == "org")
        end)

      ensure(not incompatible, :incompatible_live_grants)
    end
  end

  defp replace(credential, owner, grant, material, opts) do
    validate_current_person(owner)
    fields = material_fields(credential.auth_kind)
    material = normalize_attrs(material, fields, :invalid_material)

    ensure(
      Enum.all?(Map.take(material, @secrets), fn {_, value} -> present?(value) end),
      :invalid_material
    )

    owner_attrs =
      case owner do
        :org -> %{owner_type: "org", owner_id: nil}
        {:person, id} -> %{owner_type: "person", owner_id: id}
      end

    attrs =
      @secrets
      |> Map.new(&{&1, nil})
      |> Map.merge(%{expires_at: nil, metadata: %{}, status: "active"})
      |> Map.merge(material)
      |> Map.merge(owner_attrs)

    changeset = Grant.credential_changeset(grant || %Grant{}, credential, attrs)
    ensure(changeset.valid?, :invalid_material)
    ensure(usable?(Changeset.apply_changes(changeset), credential, now(opts)), :invalid_material)
    encrypted = encrypt_attrs(material, @secrets, opts, :invalid_material)
    changeset = force_secret_changes(changeset, encrypted)

    changeset
    |> MutationEvents.persist("grant_replaced")
    |> unwrap(:invalid_material)
    |> Repo.reload!()
  end

  defp material_fields("api_key"), do: [:api_key, :expires_at]
  defp material_fields("oauth2"), do: [:access_token, :refresh_token, :expires_at]
  defp material_fields("jwt_bearer"), do: [:private_key, :expires_at]

  defp validate_current_person(:org), do: :ok

  defp validate_current_person({:person, id}) do
    ensure(
      Repo.exists?(from p in Person, where: p.id == ^id and p.status == "active"),
      :person_unavailable
    )
  end

  defp cleanup(ref, owner, action) do
    transact(fn ->
      credential = lock_credential(ref)
      grant = lock_slot(credential.id, validate_owner(owner))
      cleanup_slot(credential.id, grant, action)
    end)
  end

  defp cleanup_slot(id, nil, _), do: %{credential_id: id, grant_id: nil, status: "absent"}

  defp cleanup_slot(id, grant, :remove) do
    unwrap(MutationEvents.delete(grant), :cleanup_failed)
    %{credential_id: id, grant_id: grant.id, status: "absent"}
  end

  defp cleanup_slot(_id, grant, :revoke) do
    attrs =
      @secrets
      |> Map.new(&{&1, nil})
      |> Map.merge(%{status: "revoked", expires_at: nil, metadata: %{}})

    grant
    |> Changeset.change(attrs)
    |> force_secret_changes(%{})
    |> MutationEvents.persist("grant_revoked")
    |> unwrap(:cleanup_failed)
    |> grant_result()
  end

  # Unreadable ciphertext loads as nil, so ordinary changeset diffing cannot prove
  # erasure. Force every secret column, including omitted replacement material.
  defp force_secret_changes(changeset, values) do
    Enum.reduce(@secrets, changeset, fn field, acc ->
      Changeset.force_change(acc, field, Map.get(values, field))
    end)
  end

  defp usable?(nil, _, _), do: false

  defp usable?(grant, credential, now) do
    grant.status == "active" and Grant.compatible_configuration?(grant, credential) and
      (is_nil(grant.expires_at) or DateTime.compare(grant.expires_at, now) == :gt) and
      required_material?(grant)
  end

  defp required_material?(%Grant{auth_kind: "api_key"} = grant), do: present?(grant.api_key)
  defp required_material?(%Grant{auth_kind: "oauth2"} = grant), do: present?(grant.access_token)

  defp required_material?(%Grant{auth_kind: "jwt_bearer"} = grant),
    do:
      Enum.all?([grant.issuer, grant.key_id], &present?/1) and
        Grant.private_key?(grant.private_key)

  defp required_material?(_), do: false

  defp present?(value) when is_binary(value),
    do: String.valid?(value) and String.trim(value) not in ["", "••••••••"]

  defp present?(_), do: false

  defp normalize_attrs(attrs, allowed, error) when is_map(attrs) and not is_struct(attrs) do
    Enum.reduce(attrs, %{}, fn {key, value}, acc ->
      field = Enum.find(allowed, &(key == &1 or key == Atom.to_string(&1)))
      ensure(not is_nil(field) and not Map.has_key?(acc, field), error)
      Map.put(acc, field, value)
    end)
  end

  defp normalize_attrs(_, _, error), do: Repo.rollback(error)

  defp validate_metadata(%{auth_kind: "oauth2", metadata: metadata}) do
    allowed = [:authorize_url, :token_url, :auth_profile, :pkce, :authorize_params]
    normalized = normalize_attrs(metadata, allowed, :invalid_configuration)

    Enum.each(normalized, fn
      {:pkce, value} ->
        ensure(is_boolean(value), :invalid_configuration)

      {:authorize_params, value} ->
        params =
          normalize_attrs(
            value,
            [:prompt, :access_type, :include_granted_scopes, :login_hint, :audience],
            :invalid_configuration
          )

        ensure(Enum.all?(params, fn {_, v} -> present?(v) end), :invalid_configuration)

      {_, value} ->
        ensure(present?(value), :invalid_configuration)
    end)
  end

  defp validate_metadata(%{metadata: metadata}) do
    normalized = normalize_attrs(metadata, [:auth_profile_id, :subject], :invalid_configuration)
    ensure(Enum.all?(normalized, fn {_, value} -> present?(value) end), :invalid_configuration)
  end

  defp encrypt_attrs(attrs, fields, opts, error) do
    Enum.reduce(Map.take(attrs, fields), attrs, fn {field, value}, acc ->
      ensure(present?(value), error)

      case SecretConfig.encrypt(value, opts) do
        {:ok, ciphertext} -> Map.put(acc, field, ciphertext)
        {:error, _} -> Repo.rollback(:encryption_failed)
      end
    end)
  end

  defp now(opts), do: DateUtils.now(opts)

  defp grant_result(grant),
    do: %{credential_id: grant.credential_id, grant_id: grant.id, status: grant.status}

  defp ensure(true, _), do: :ok
  defp ensure(false, error), do: Repo.rollback(error)
  defp unwrap({:ok, value}, _), do: value
  defp unwrap({:error, _}, error), do: Repo.rollback(error)
end
