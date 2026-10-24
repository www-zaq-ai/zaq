defmodule Zaq.Engine.Connect.CredentialDocuments do
  @moduledoc """
  Atomic encrypted documents for trusted connector runtimes.

  This domain API requires a previously provisioned, bidirectional association:
  the connector's `credential_document_id` setting and an API-key credential with
  metadata `auth_profile_id: credential_document_v1`, `subject: channel_config:<id>`.
  Explicit `:bind` provisioning creates the association once. Protocol serialization
  belongs to callers. No provider types, runtime profiles or automatic credential
  reactivation live here; record operations never recreate a missing grant.

  Cross-role callers use the confidential synchronous `:credential_document`
  Engine action with explicit trusted runtime authorization. Binding IDs alone
  are not authorization for exposing this privileged domain API to users/tools.

  Connector, credential and grant locks cover read/validate/merge/write. Canonical
  Connect resolution and mutations retain usability, encryption and transactional
  notification contracts. Identical writes are silent. Missing records return
  `:error`; missing grants, corrupt state and infrastructure failures are errors.
  Operations compose with an outer Engine transaction, whose caller owns commit.
  The routed operation returns only after its transaction commits.

  `:put_many` merges a map of `{namespace, key} => binary` records in one grant
  replacement and notification. It shares the single-write validation and limits;
  invalid batches leave the document unchanged and identical batches are silent.

  Version 1 is JSON with `version` and `records` (namespace/key/Base64 value).
  Documents are bounded to 16 MiB, binary values to 1 MiB and UTF-8 addresses to
  512 bytes. This data is private runtime state, never HTTP authentication.
  """

  import Ecto.Query

  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant}
  alias Zaq.Repo

  @max_document_bytes 16 * 1024 * 1024
  @max_value_bytes 1024 * 1024
  @timeout 5_000

  @doc "Executes one bounded record operation for an explicitly bound trusted runtime."
  @spec execute(map()) :: :ok | :error | {:ok, map() | binary() | [String.t()]} | {:error, atom()}
  def execute(request) do
    with :ok <- validate_request(request) do
      transact(request)
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :storage_unavailable}
  end

  defp transact(request) do
    case Repo.transaction(fn -> execute_locked(request) end, timeout: @timeout) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_locked(%{binding: binding} = request) do
    config =
      Repo.one(
        from c in ChannelConfig, where: c.id == ^binding.channel_config_id, lock: "FOR UPDATE"
      )

    ensure(
      match?(%ChannelConfig{enabled: true, archived_at: nil}, config),
      :connector_unavailable
    )

    ensure_provider(config, request)
    ensure(config.settings["credential_document_id"] == binding.credential_id, :invalid_binding)

    credential =
      Repo.one(from c in Credential, where: c.id == ^binding.credential_id, lock: "FOR UPDATE")

    ensure(valid_credential?(credential, config), :invalid_binding)

    resolved = resolve(credential.id)
    grant = Repo.get!(Grant, resolved.grant_id)
    records = decode(resolved.authentication.api_key)
    {result, updated} = operate(request, records)

    if updated != records do
      encoded = Jason.encode!(%{version: 1, records: updated})
      ensure(byte_size(encoded) <= @max_document_bytes, :document_too_large)

      case Connect.replace_credential_grant(credential.id, :org, %{
             api_key: encoded,
             expires_at: grant.expires_at
           }) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end

    result
  end

  defp execute_locked(%{op: :bind, channel_config_id: id} = request) do
    config = Repo.one(from c in ChannelConfig, where: c.id == ^id, lock: "FOR UPDATE")

    ensure(
      match?(%ChannelConfig{enabled: true, archived_at: nil}, config),
      :connector_unavailable
    )

    ensure_provider(config, request)
    credential_id = config.settings["credential_document_id"] || provision(config)
    binding = %{channel_config_id: id, credential_id: credential_id}
    execute_locked(%{binding: binding, op: :list_keys, namespace: "__binding_check__"})
    {:ok, binding}
  end

  defp provision(config) do
    case Connect.save_credential_configuration(
           nil,
           %{
             name: "Connector document #{config.id}",
             provider: config.provider,
             auth_kind: "api_key",
             secret_binding: :grant,
             personal_credential_policy: :disabled,
             metadata: %{
               "auth_profile_id" => "credential_document_v1",
               "subject" => "channel_config:#{config.id}"
             }
           },
           {:replace, %{api_key: Jason.encode!(%{version: 1, records: %{}})}}
         ) do
      {:ok, saved} ->
        config
        |> Ecto.Changeset.change(
          settings: Map.put(config.settings, "credential_document_id", saved.credential_id)
        )
        |> Repo.update!()

        saved.credential_id

      {:error, _} ->
        Repo.rollback(:credential_unavailable)
    end
  end

  defp valid_credential?(%Credential{} = credential, config) do
    credential.auth_kind == "api_key" and credential.secret_binding == :grant and
      credential.personal_credential_policy == :disabled and
      credential.provider == config.provider and
      credential.metadata["auth_profile_id"] == "credential_document_v1" and
      credential.metadata["subject"] == "channel_config:#{config.id}"
  end

  defp valid_credential?(_, _), do: false

  defp resolve(id) do
    case Connect.resolve_credential(id, nil) do
      {:ok, resolved} -> resolved
      {:error, %{reason: reason}} -> Repo.rollback(reason)
    end
  end

  defp validate_request(
         %{binding: %{channel_config_id: config_id, credential_id: credential_id}} = request
       )
       when is_integer(config_id) and config_id > 0 and config_id <= 9_223_372_036_854_775_807 and
              is_integer(credential_id) and credential_id > 0 and
              credential_id <= 9_223_372_036_854_775_807 do
    if valid_operation?(request), do: :ok, else: {:error, :invalid_request}
  end

  defp validate_request(%{op: :bind, channel_config_id: id})
       when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807, do: :ok

  defp validate_request(_), do: {:error, :invalid_request}

  defp valid_operation?(%{op: :clear}), do: true

  defp valid_operation?(%{op: op, namespace: namespace})
       when op in [:list_keys, :delete_namespace],
       do: address?(namespace)

  defp valid_operation?(%{op: :put, namespace: namespace, key: key, value: value}) do
    valid_write?({{namespace, key}, value})
  end

  defp valid_operation?(%{op: :put_many, records: records}) when is_map(records),
    do: Enum.all?(records, &valid_write?/1)

  defp valid_operation?(%{op: op, namespace: namespace, key: key}) when op in [:get, :delete],
    do: address?(namespace) and address?(key)

  defp valid_operation?(_), do: false

  defp valid_write?({{namespace, key}, value}) do
    address?(namespace) and address?(key) and is_binary(value) and
      byte_size(value) <= @max_value_bytes
  end

  defp valid_write?(_), do: false

  defp address?(value) when is_binary(value),
    do: byte_size(value) in 1..512 and String.valid?(value)

  defp address?(_), do: false

  defp decode(encoded) when is_binary(encoded) and byte_size(encoded) <= @max_document_bytes do
    case Jason.decode(encoded) do
      {:ok, %{"version" => 1, "records" => records} = document}
      when map_size(document) == 2 and is_map(records) ->
        ensure(Enum.all?(records, &valid_namespace?/1), :corrupt_document)
        records

      _ ->
        Repo.rollback(:corrupt_document)
    end
  end

  defp decode(_), do: Repo.rollback(:corrupt_document)

  defp valid_namespace?({namespace, records}) when is_map(records),
    do: address?(namespace) and Enum.all?(records, &valid_record?/1)

  defp valid_namespace?(_), do: false

  defp valid_record?({key, value}) when is_binary(value) do
    address?(key) and byte_size(value) <= div(@max_value_bytes + 2, 3) * 4 and
      case Base.decode64(value) do
        {:ok, decoded} -> byte_size(decoded) <= @max_value_bytes
        :error -> false
      end
  end

  defp valid_record?(_), do: false

  defp operate(%{op: :get, namespace: namespace, key: key}, records) do
    result =
      case Map.fetch(Map.get(records, namespace, %{}), key) do
        {:ok, encoded} -> {:ok, Base.decode64!(encoded)}
        :error -> :error
      end

    {result, records}
  end

  defp operate(%{op: :list_keys, namespace: namespace}, records),
    do: {{:ok, records |> Map.get(namespace, %{}) |> Map.keys() |> Enum.sort()}, records}

  defp operate(%{op: :put, namespace: namespace, key: key, value: value}, records) do
    namespace_records = records |> Map.get(namespace, %{}) |> Map.put(key, Base.encode64(value))
    {:ok, Map.put(records, namespace, namespace_records)}
  end

  defp operate(%{op: :put_many, records: writes}, records) do
    updated =
      Enum.reduce(writes, records, fn {{namespace, key}, value}, acc ->
        {:ok, updated} = operate(%{op: :put, namespace: namespace, key: key, value: value}, acc)
        updated
      end)

    {:ok, updated}
  end

  defp operate(%{op: :delete, namespace: namespace, key: key}, records) do
    namespace_records = records |> Map.get(namespace, %{}) |> Map.delete(key)

    updated =
      if map_size(namespace_records) == 0,
        do: Map.delete(records, namespace),
        else: Map.put(records, namespace, namespace_records)

    {:ok, updated}
  end

  defp operate(%{op: :clear}, _records), do: {:ok, %{}}

  defp operate(%{op: :delete_namespace, namespace: namespace}, records),
    do: {:ok, Map.delete(records, namespace)}

  defp ensure_provider(config, request) do
    ensure(
      Map.get(request, :expected_provider, config.provider) == config.provider,
      :invalid_provider
    )
  end

  defp ensure(true, _reason), do: :ok
  defp ensure(false, reason), do: Repo.rollback(reason)
end
