defmodule Zaq.Engine.Connect.Snapshot do
  @moduledoc false

  alias Zaq.Repo

  @spec credential(pos_integer(), keyword()) :: binary()
  def credential(id, opts \\ []) do
    projection =
      if Keyword.get(opts, :timestamps, true),
        do: "to_jsonb(c)",
        else: "to_jsonb(c) - 'inserted_at' - 'updated_at'"

    %{rows: [[row]]} =
      Repo.query!("SELECT #{projection} FROM connect_credentials c WHERE id = $1", [id])

    digest(row)
  end

  @spec grant_with_credential(pos_integer()) :: binary()
  def grant_with_credential(id) do
    %{rows: [[grant, credential]]} =
      Repo.query!(
        "SELECT to_jsonb(g), to_jsonb(c) FROM connect_grants g JOIN connect_credentials c ON c.id = g.credential_id WHERE g.id = $1",
        [id]
      )

    digest({grant, credential})
  end

  defp digest(value), do: :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
end
