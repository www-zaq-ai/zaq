defmodule Zaq.Engine.Actions.ConfirmLinkedDevice do
  @moduledoc """
  Atomically persists an authorized adapter account and encoded credentials.

  Trusted BO session identity supplies ownership. An attempt UUID serializes repeated
  confirmations, including lost replies, while connector creation and encrypted
  record provisioning commit together. No provider/RPC callback runs in this
  transaction; Channels seeds RAM and activates the connection after commit.
  Provider identity validation and opaque record encoding belong to the adapter.
  """
  use Jido.Action,
    name: "confirm_linked_device",
    description: "Atomically save a confirmed linked-device connector and session",
    schema: Zoi.object(%{request: Zoi.any()}),
    output_schema: Zoi.object(%{result: Zoi.any()})

  import Ecto.Query
  alias Ecto.Adapters.SQL
  alias Zaq.Engine.{ChannelConfig, Connect}
  alias Zaq.Repo

  def run(%{request: request}, %{
        actor: %{user_id: id},
        linked_device_runtime: true,
        skip_permissions: true
      })
      when is_map(request) and is_integer(id) and id > 0 do
    {:ok, %{result: save(Map.put(request, :owner_id, id))}}
  end

  def run(_, _), do: {:error, :unauthorized}

  defp save(%{
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

  defp save(_), do: {:error, :invalid_snapshot}

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
        nil -> create(attempt, provider, owner_id, account, records)
        config -> verified_existing(config, provider, owner_id, account)
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
    settings = %{
      "pairing_attempt" => attempt,
      "owner_id" => owner_id,
      "account" => Map.take(account, [:external_id, :display_name])
    }

    config =
      case ChannelConfig.create(
             %{
               name: account[:display_name] || account.external_id,
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
