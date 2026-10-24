defmodule Zaq.Engine.LinkedDeviceConfirmation do
  @moduledoc """
  Atomically creates a confirmed adapter connector and its encrypted credentials.

  Accepts opaque, package-encoded records via the trusted Channels runtime Action.
  The attempt UUID serializes repeated confirmations, including a lost response;
  persistence never starts a connection while the transaction is open. Channels
  supplies authorized callbacks; the package excludes volatile messaging sessions
  and seeds its local RAM backend after this commits.

  Accounts use the shared `external_id` and optional `display_name` fields.
  Provider-specific identity validation belongs to the adapter.
  """
  import Ecto.Query
  alias Ecto.Adapters.SQL
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Repo

  def save(%{
        attempt_id: attempt,
        provider: provider,
        account: %{external_id: external_id} = account,
        credentials: records,
        owner_id: owner_id
      })
      when is_binary(attempt) and is_binary(provider) and is_binary(external_id) and
             is_integer(owner_id) and is_map(records) and map_size(records) > 0 do
    with {:ok, _} <- Ecto.UUID.cast(attempt),
         true <- byte_size(provider) > 0 and byte_size(provider) <= 64,
         true <- byte_size(external_id) > 0 and byte_size(external_id) <= 255 do
      persist(attempt, provider, owner_id, account, records)
    else
      _ -> {:error, :invalid_identity}
    end
  end

  def save(_), do: {:error, :invalid_snapshot}

  defp persist(attempt, provider, owner_id, account, records) do
    Repo.transaction(fn ->
      SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "linked-device:" <> attempt
      ])

      existing =
        Repo.one(
          from c in ChannelConfig,
            where: fragment("?->>'pairing_attempt' = ?", c.settings, ^attempt)
        )

      case existing do
        nil ->
          create(attempt, provider, owner_id, account, records)

        config ->
          verified_existing(config, provider, owner_id, account)
      end
    end)
  end

  defp verified_existing(config, provider, owner_id, account) do
    if matching_attempt?(config, provider, owner_id, account),
      do: config,
      else: Repo.rollback(:conflicting_attempt)
  end

  defp matching_attempt?(config, provider, owner_id, account) do
    saved_account = config.settings["account"]
    saved_external_id = if is_map(saved_account), do: saved_account["external_id"]

    config.provider == provider and config.settings["owner_id"] == owner_id and
      saved_external_id == account.external_id
  end

  defp create(attempt, provider, owner_id, account, records) do
    name = account[:display_name] || account.external_id

    settings = %{
      "pairing_attempt" => attempt,
      "owner_id" => owner_id,
      "account" => Map.take(account, [:external_id, :display_name])
    }

    config =
      case ChannelConfig.create(
             %{
               name: name,
               provider: provider,
               kind: "retrieval",
               enabled: true,
               settings: settings
             },
             adapter_authentication: true
           ) do
        {:ok, config} -> config
        {:error, changeset} -> Repo.rollback(changeset)
      end

    binding =
      case Connect.credential_document(%{op: :bind, channel_config_id: config.id}) do
        {:ok, binding} -> binding
        {:error, reason} -> Repo.rollback(reason)
      end

    case Connect.credential_document(%{op: :put_many, binding: binding, records: records}) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    Repo.get!(ChannelConfig, config.id)
  end
end
