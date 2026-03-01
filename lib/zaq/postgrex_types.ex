Postgrex.Types.define(
  Zaq.PostgrexTypes,
  [Pgvector.Extensions.Vector, Pgvector.Extensions.Halfvec] ++
    Ecto.Adapters.Postgres.extensions(),
  []
)
