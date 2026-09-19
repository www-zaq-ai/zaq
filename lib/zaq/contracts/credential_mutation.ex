defmodule Zaq.Contracts.CredentialMutation do
  @moduledoc """
  Secret-free versioned contract shared by Connect mutation publishers and Agent receivers.

  This module validates transport shape only. It performs no persistence, delivery,
  credential resolution, or Agent lifecycle work.
  """

  @credential_kinds ~w(credential_created credential_updated credential_deleted)
  @grant_kinds ~w(grant_created grant_replaced grant_revoked grant_deleted grant_tokens_updated)
  @keys ~w(version event_id credential_id grant_id owner_type owner_id kind occurred_at)

  @doc "Validates the complete notification allowlist and rejects additional keys."
  @spec validate(term()) :: :ok | {:error, :invalid_mutation_event}
  def validate(
        %{
          "version" => 1,
          "event_id" => event_id,
          "credential_id" => id,
          "occurred_at" => timestamp
        } = payload
      )
      when map_size(payload) == 8 do
    with true <- Enum.all?(@keys, &Map.has_key?(payload, &1)),
         true <- positive_id?(id),
         {:ok, ^event_id} <- Ecto.UUID.cast(event_id),
         true <- is_binary(timestamp),
         {:ok, _, 0} <- DateTime.from_iso8601(timestamp),
         true <- valid_identity?(payload) do
      :ok
    else
      _ -> {:error, :invalid_mutation_event}
    end
  end

  def validate(_), do: {:error, :invalid_mutation_event}

  defp valid_identity?(%{
         "kind" => kind,
         "grant_id" => nil,
         "owner_type" => nil,
         "owner_id" => nil
       }),
       do: kind in @credential_kinds

  defp valid_identity?(%{
         "kind" => kind,
         "grant_id" => id,
         "owner_type" => owner,
         "owner_id" => owner_id
       }) do
    kind in @grant_kinds and positive_id?(id) and
      ((owner in ["org", "user"] and (is_nil(owner_id) or is_integer(owner_id))) or
         (owner == "person" and positive_id?(owner_id)))
  end

  defp positive_id?(id), do: is_integer(id) and id > 0
end
