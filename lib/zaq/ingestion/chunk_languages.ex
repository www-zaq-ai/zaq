defmodule Zaq.Ingestion.ChunkLanguages do
  @moduledoc """
  ETS-backed inventory of languages present in persisted chunks on the ingestion node.

  The database remains authoritative. Writes invalidate local and remote copies;
  a short TTL repairs missed notifications and deletions performed outside the
  normal chunk API. The inventory is intentionally not permission-filtered.
  """

  use GenServer

  import Ecto.Query

  alias Zaq.Ingestion.Chunk
  alias Zaq.Repo

  @topic "ingestion:chunk_languages"
  @ttl_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Lists distinct languages from all persisted searchable chunks."
  def list do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :list)
    else
      load_languages()
    end
  end

  @doc "Invalidates inventory after a committed chunk write or deletion."
  def invalidate do
    Phoenix.PubSub.broadcast(Zaq.PubSub, @topic, :chunk_languages_changed)
    :ok
  end

  @impl true
  def init(_opts) do
    table = :ets.new(__MODULE__, [:set, :protected])
    Phoenix.PubSub.subscribe(Zaq.PubSub, @topic)
    {:ok, table}
  end

  @impl true
  def handle_call(:list, _from, table) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(table, :languages) do
      [{:languages, languages, expires_at}] when expires_at > now ->
        {:reply, languages, table}

      _ ->
        languages = load_languages()
        :ets.insert(table, {:languages, languages, now + @ttl_ms})
        {:reply, languages, table}
    end
  end

  @impl true
  def handle_info(:chunk_languages_changed, table) do
    :ets.delete(table, :languages)
    {:noreply, table}
  end

  defp load_languages do
    case Repo.query("SELECT to_regclass('public.chunks')", []) do
      {:ok, %{rows: [[nil]]}} ->
        []

      {:ok, _} ->
        Repo.all(from(c in Chunk, distinct: c.language, select: c.language))
        |> Enum.map(&(&1 || "simple"))
        |> Enum.uniq()
        |> Enum.sort()

      {:error, reason} ->
        raise "Cannot discover chunk languages: #{inspect(reason)}"
    end
  end
end
