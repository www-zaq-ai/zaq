defmodule Zaq.Records.Limits do
  @moduledoc """
  Ceilings on what a record may carry across a node boundary.

  Distinct from per-call `max_bytes` on a descriptor, which is a *caller's* statement about
  what it can accept. This is the platform's statement about what the cluster can survive,
  and it wins regardless of what any caller asked for.

  ## Why a hard ceiling exists at all

  A record moves between nodes as a distributed Erlang message. A base64-encoded video is not
  a slow message, it is a node-destabilising one — it inflates 4/3 on the way in, sits whole
  in memory on both sides, and blocks the distribution port while it copies. Above the
  ceiling the intended answer is *don't move the bytes*: materialize to a location both sides
  can reach and pass a handle, which the descriptor already expresses.

  Overridable via `config :zaq, :records, transport_max_bytes: ...`, mainly so a deployment
  with a bigger cluster budget can raise it and tests can lower it.
  """

  @defaults %{
    transport_max_bytes: 16 * 1024 * 1024
  }

  @spec all(keyword()) :: map()
  def all(opts \\ []) do
    overrides = Zaq.Config.get(:zaq, :records, %{}, opts) |> Map.new()
    Map.merge(@defaults, overrides)
  end

  @spec get(atom(), keyword()) :: term()
  def get(key, opts \\ []) when is_atom(key), do: Map.fetch!(all(opts), key)
end
