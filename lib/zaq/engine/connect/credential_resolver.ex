defmodule Zaq.Engine.Connect.CredentialResolver do
  @moduledoc """
  Privileged runtime-only canonical credential selection, independent of consumers.

  Trusted actors are normalized with `ActorNormalizer.person_id/1`, not authenticated
  here. Every non-null identity claim must agree and name a literal current active
  Person before any policy is evaluated. Aliases never reidentify ownership. Genuine
  non-Person actors (including nil) deliberately select org for all policies; this
  capability must never be exposed as a public Engine action or Person read API.

  Ownership is selected before usability. Disabled ignores personal rows; optional
  uses an existing personal row in any status, otherwise org; required needs a personal
  row. A selected failure never falls back. Configuration secrets are never sources.

  Local resolution linearizes at the final credential-first locked read and active
  identity check. OAuth alone leaves locks to call `Connect.prepare_grant_for_use/2`
  once, then reacquires them, checks raw configuration fingerprint and pinned selection,
  and rejects a superseded prepared grant. Refresh owns its raw material/claim checks.
  There are no in-call retries or new revision infrastructure. Mutations after the
  final check, Person deletion after its check and later server creation/invalidation
  races require consumer/lifecycle coordination outside this boundary.
  """

  import Ecto.Query
  alias Zaq.Accounts.Person
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant, Refresh, ResolvedCredential, Snapshot}
  alias Zaq.Identity.ActorNormalizer
  alias Zaq.Repo
  alias Zaq.Utils.DateUtils

  @auth_fields ~w(provider auth_kind request_format scopes issuer key_id)a
  @configuration_fields @auth_fields ++
                          ~w(id personal_credential_policy metadata expires_at client_id)a
  @type credential_ref :: Credential.t() | pos_integer() | String.t()
  @type reason ::
          :person_unavailable
          | :personal_credential_required
          | :global_credential_missing
          | :credential_revoked
          | :credential_expired
          | :credential_unavailable
          | :credential_refresh_failed
          | :credential_refresh_busy
  @type result ::
          {:ok, ResolvedCredential.t()}
          | {:error, %{credential_id: pos_integer() | nil, reason: reason()}}

  @doc "Resolves one canonical owner slot; opts carry the existing now/config/refresh window seams."
  @spec resolve_credential(credential_ref(), ActorNormalizer.actor(), keyword()) :: result()
  def resolve_credential(reference, actor, opts \\ []) do
    id = credential_id(reference)
    now = DateUtils.now(opts)

    result =
      with {:ok, person_id} <- actor_identity(actor),
           {:ok, selected} <- select_credential(id, person_id, now) do
        complete(selected, person_id, opts)
      end

    case result do
      {:ok, _} = success -> success
      {:error, reason} -> {:error, %{credential_id: id, reason: reason}}
    end
  end

  defp credential_id(%Credential{id: id}), do: credential_id(id)

  defp credential_id(id) when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807,
    do: id

  defp credential_id(id) when is_binary(id), do: credential_id(ActorNormalizer.normalize_id(id))
  defp credential_id(_), do: nil

  defp actor_identity(nil), do: {:ok, nil}

  defp actor_identity(actor) when is_map(actor) and not is_struct(actor) do
    id = ActorNormalizer.person_id(actor)

    claims =
      Enum.flat_map([:person, "person", :person_id, "person_id"], &identity_claim(actor, &1))

    if Enum.all?(claims, &(is_integer(&1) and &1 > 0 and &1 == id)) and
         (is_nil(id) or credential_id(id) == id),
       do: current_person(id),
       else: {:error, :person_unavailable}
  end

  defp actor_identity(_), do: {:error, :person_unavailable}

  defp identity_claim(actor, key) do
    case Map.get(actor, key) do
      nil -> []
      value when key in [:person, "person"] -> nested_claims(value)
      value -> [ActorNormalizer.normalize_id(value)]
    end
  end

  defp nested_claims(value) when is_map(value) do
    values =
      for key <- [:id, "id"],
          Map.has_key?(value, key),
          do: ActorNormalizer.normalize_id(Map.get(value, key))

    if values == [], do: [nil], else: values
  end

  defp nested_claims(_), do: [nil]

  defp current_person(nil), do: {:ok, nil}

  defp current_person(id) do
    if Repo.exists?(from p in Person, where: p.id == ^id and p.status == "active"),
      do: {:ok, id},
      else: {:error, :person_unavailable}
  end

  defp select_credential(id, person_id, now) do
    Repo.transaction(fn ->
      c = configuration(id)
      require_person(person_id)
      g = selected_grant(c, person_id)
      validate_selection(c, g, now)

      if g.auth_kind == "oauth2" do
        %{
          credential: c,
          grant: g,
          fingerprint: config_fingerprint(c.id),
          grant_fingerprint: Refresh.fingerprint(g.id)
        }
      else
        resolved(c, g, now)
      end
    end)
  end

  defp configuration(nil), do: Repo.rollback(:credential_unavailable)

  defp configuration(id) do
    Repo.one(
      from c in Credential,
        where: c.id == ^id,
        lock: "FOR UPDATE",
        select: struct(c, ^@configuration_fields)
    ) ||
      Repo.rollback(:credential_unavailable)
  end

  defp selected_grant(c, nil), do: global(c)
  defp selected_grant(%Credential{personal_credential_policy: :disabled} = c, _), do: global(c)

  defp selected_grant(c, person_id) do
    case slot(c.id, "person", person_id) do
      nil when c.personal_credential_policy == :required ->
        Repo.rollback(:personal_credential_required)

      nil ->
        global(c)

      grant ->
        grant
    end
  end

  defp global(c), do: slot(c.id, "org", nil) || Repo.rollback(:global_credential_missing)

  defp slot(id, type, owner_id) do
    query =
      from g in Grant,
        where:
          g.credential_id == ^id and g.resource_type == "connect_credential" and
            g.resource_id == ^to_string(id) and g.owner_type == ^type,
        lock: "FOR UPDATE"

    query =
      if is_nil(owner_id),
        do: where(query, [g], is_nil(g.owner_id)),
        else: where(query, [g], g.owner_id == ^owner_id)

    Repo.one(query)
  end

  defp complete(%ResolvedCredential{} = result, _, _), do: {:ok, result}

  defp complete(snapshot, person_id, opts) do
    prepared =
      Connect.prepare_grant_for_use(
        snapshot.grant,
        Keyword.put(opts, :expected_fingerprint, snapshot.grant_fingerprint)
      )

    with {:ok, _} <- current_person(person_id) do
      finish_oauth(snapshot, prepared, person_id, opts)
    end
  end

  defp finish_oauth(snapshot, {:ok, prepared}, person_id, opts) do
    Repo.transaction(fn ->
      c = configuration(snapshot.credential.id)
      require_person(person_id)
      ensure(config_fingerprint(c.id) == snapshot.fingerprint, :credential_unavailable)
      # Never reinterpret a disappeared personal row as permission to use org.
      g = slot(c.id, snapshot.grant.owner_type, snapshot.grant.owner_id)
      ensure(not is_nil(g) and g.id == snapshot.grant.id, :credential_unavailable)
      ensure(selected_grant(c, person_id).id == g.id, :credential_unavailable)
      now = DateUtils.now(opts)
      validate_selection(c, g, now)
      ensure(Map.from_struct(g) == Map.from_struct(prepared), :credential_unavailable)

      ensure(
        prepared != snapshot.grant or Refresh.fingerprint(g.id) == snapshot.grant_fingerprint,
        :credential_unavailable
      )

      resolved(c, g, now)
    end)
  end

  defp finish_oauth(snapshot, {:error, reason}, _, opts),
    do: {:error, refresh_reason(reason, snapshot.grant, DateUtils.now(opts))}

  defp refresh_reason(:person_unavailable, _, _), do: :person_unavailable
  defp refresh_reason(:revoked, _, _), do: :credential_revoked
  defp refresh_reason(:refresh_busy, _, _), do: :credential_refresh_busy
  defp refresh_reason(:refresh_failed, _, _), do: :credential_refresh_failed

  defp refresh_reason(:authentication_required, grant, now) do
    if grant.status == "expired" or expired?(grant.expires_at, now),
      do: :credential_expired,
      else: :credential_unavailable
  end

  defp refresh_reason(_, _, _), do: :credential_unavailable

  defp validate_selection(c, g, now) do
    ensure(g.status != "revoked", :credential_revoked)
    ensure(g.status in ["active", "expired"], :credential_unavailable)

    ensure(
      c.auth_kind in ["api_key", "oauth2", "jwt_bearer"] and
        c.request_format in ["bearer", "raw"],
      :credential_unavailable
    )

    ensure(Grant.compatible_configuration?(g, c), :credential_unavailable)

    ensure(not expired?(c.expires_at, now), :credential_expired)

    ensure(
      present?(c.provider) and (c.auth_kind != "oauth2" or present?(c.client_id)),
      :credential_unavailable
    )
  end

  defp resolved(c, g, now) do
    ensure(g.status != "expired" and not expired?(g.expires_at, now), :credential_expired)
    auth = authentication(c, g)

    %ResolvedCredential{
      credential_id: c.id,
      grant_id: g.id,
      owner_type: g.owner_type,
      owner_id: g.owner_id,
      auth_kind: g.auth_kind,
      request_format: g.request_format,
      authentication: auth,
      expires_at: g.expires_at,
      metadata: account_metadata(g.metadata)
    }
  end

  defp authentication(_, %Grant{auth_kind: "api_key", api_key: key}) do
    ensure(present?(key), :credential_unavailable)
    %{api_key: key}
  end

  defp authentication(_, %Grant{auth_kind: "oauth2", access_token: token}) do
    ensure(present?(token), :credential_unavailable)
    %{access_token: token}
  end

  defp authentication(c, %Grant{auth_kind: "jwt_bearer"} = g) do
    profile = Zaq.Utils.Map.read_any(c.metadata || %{}, ["auth_profile_id", :auth_profile_id])

    ensure(
      profile in ["service_account", "domain_delegated_service_account"],
      :credential_unavailable
    )

    ensure(
      profile != "domain_delegated_service_account" or present?(g.subject),
      :credential_unavailable
    )

    ensure(
      present?(g.issuer) and present?(g.key_id) and Grant.private_key?(g.private_key),
      :credential_unavailable
    )

    Map.take(g, [:private_key, :issuer, :key_id, :subject, :scopes])
    |> Map.put(:auth_profile_id, profile)
  end

  defp account_metadata(metadata) do
    metadata
    |> Map.take(["account_id", "account_name"])
    |> Map.filter(fn {_, value} ->
      is_binary(value) and String.valid?(value) and byte_size(value) <= 255
    end)
  end

  defp present?(value) when is_binary(value),
    do: String.valid?(value) and String.trim(value) not in ["", "••••••••"]

  defp present?(_), do: false
  defp expired?(nil, _), do: false
  defp expired?(%DateTime{} = expiry, now), do: DateTime.compare(expiry, now) != :gt

  # Same raw JSONB fingerprint technique as OAuth attempts/refresh; never a public revision.
  defp config_fingerprint(id) do
    Snapshot.credential(id)
  end

  defp ensure(valid?, reason), do: unless(valid?, do: Repo.rollback(reason))

  defp require_person(id) do
    ensure(current_person(id) == {:ok, id}, :person_unavailable)
  end
end
