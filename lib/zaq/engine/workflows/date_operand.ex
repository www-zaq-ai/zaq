defmodule Zaq.Engine.Workflows.DateOperand do
  @moduledoc """
  Parses and normalizes date/datetime operands for condition evaluation.

  This is the sole owner of date parsing and the injectable clock used by
  `Zaq.Engine.Workflows.EdgeCondition` when a condition carries a
  `type: "date"` / `type: "datetime"`. Comparison itself stays in
  `EdgeCondition`; this module only turns the two operand shapes into a
  `%Date{}` / `%DateTime{}` pair (both in UTC).

  ## Two operand roles

  - **actual** — the value pulled from the run fact (`coerce_actual/2`). It is
    already a concrete value: a `%Date{}`, `%DateTime{}`, `%NaiveDateTime{}`, or
    an ISO8601 string.
  - **expected** — the static/authored side (`resolve_expected/3`). It accepts a
    richer vocabulary so a workflow can be written without hardcoding a clock:

    | Shape | Example | Meaning |
    |---|---|---|
    | ISO8601 string | `"2026-07-06"`, `"2026-07-06T10:00:00Z"` | a fixed instant |
    | sentinel | `"today"`, `"now"` | resolved against the clock |
    | relative map | `%{"from" => "today", "days" => -7}` | clock ± offset |

    The relative map accepts `"days"`, `"hours"`, `"minutes"`, and `"seconds"`
    (positive or negative), summed onto the `"from"` base (`"now"` / `"today"`).
    "older than 7 days" is `%{"from" => "today", "days" => -7}` compared with `lt`.

  ## Type semantics

  - `"date"` — both operands are truncated to a `%Date{}`; comparison is by
    calendar day (UTC). This fixes the term-order bug where `Kernel` comparison of
    `%Date{}` structs sorts by map key (`calendar, day, month, year`), not chronology.
  - `"datetime"` — both operands are `%DateTime{}` in UTC.

  ## Clock injection

  The current instant is taken from `opts[:now]` when a `%DateTime{}` is supplied
  (async-safe, no global state — used by tests). Otherwise it falls back to a
  configured 0-arity clock (`Zaq.Config.get(:zaq, __MODULE__, [], opts)` →
  `:clock`), defaulting to `&DateTime.utc_now/0`.

  Every function is total: unparseable input returns `:error`, never raises.
  """

  @unit_keys [{"days", :day}, {"hours", :hour}, {"minutes", :minute}, {"seconds", :second}]

  @type resolved :: Date.t() | DateTime.t()

  @doc """
  Resolves the static/authored side of a condition to a `%Date{}`/`%DateTime{}`.

  Accepts an ISO8601 string, a sentinel (`"today"`/`"now"`), or a relative map
  (`%{"from" => "now"|"today", "days"|"hours"|"minutes"|"seconds" => integer}`).
  Returns `{:ok, resolved}` or `:error`. Never raises.
  """
  @spec resolve_expected(term(), String.t(), keyword()) :: {:ok, resolved()} | :error
  def resolve_expected(value, type, opts \\ [])

  def resolve_expected(value, "date", opts) do
    case to_datetime_expected(value, opts) do
      {:ok, dt} -> {:ok, DateTime.to_date(dt)}
      :error -> :error
    end
  end

  def resolve_expected(value, "datetime", opts) do
    to_datetime_expected(value, opts)
  end

  def resolve_expected(_value, _type, _opts), do: :error

  @doc """
  Coerces a concrete fact value to a `%Date{}`/`%DateTime{}` for comparison.

  Accepts `%Date{}`, `%DateTime{}`, `%NaiveDateTime{}`, or an ISO8601 string.
  Returns `{:ok, resolved}` or `:error`. Never raises.
  """
  @spec coerce_actual(term(), String.t()) :: {:ok, resolved()} | :error
  def coerce_actual(value, "date"), do: to_date(value)
  def coerce_actual(value, "datetime"), do: to_datetime(value)
  def coerce_actual(_value, _type), do: :error

  # -- expected-side parsing -------------------------------------------------

  defp to_datetime_expected("now", opts), do: base("now", opts)
  defp to_datetime_expected("today", opts), do: base("today", opts)

  defp to_datetime_expected(value, _opts) when is_binary(value), do: parse_datetime_string(value)

  defp to_datetime_expected(%{} = map, opts) do
    with {:ok, from} <- base(map_get(map, "from"), opts) do
      apply_offset(from, map)
    end
  end

  defp to_datetime_expected(_value, _opts), do: :error

  defp base("now", opts), do: {:ok, now(opts)}

  defp base("today", opts) do
    {:ok, %{now(opts) | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}}
  end

  defp base(_other, _opts), do: :error

  defp apply_offset(base, map) do
    Enum.reduce_while(@unit_keys, {:ok, base}, fn {key, unit}, {:ok, acc} ->
      case fetch_int(map, key) do
        :absent -> {:cont, {:ok, acc}}
        {:ok, n} -> {:cont, {:ok, DateTime.add(acc, n, unit)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp fetch_int(map, key) do
    case map_get(map, key) do
      nil -> :absent
      n when is_integer(n) -> {:ok, n}
      _ -> :error
    end
  end

  # -- actual-side coercion --------------------------------------------------

  defp to_date(%Date{} = d), do: {:ok, d}
  defp to_date(%DateTime{} = dt), do: {:ok, DateTime.to_date(dt)}
  defp to_date(%NaiveDateTime{} = ndt), do: {:ok, NaiveDateTime.to_date(ndt)}

  defp to_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, d} -> {:ok, d}
      _ -> with {:ok, dt} <- parse_datetime_string(str), do: {:ok, DateTime.to_date(dt)}
    end
  end

  defp to_date(_), do: :error

  defp to_datetime(%DateTime{} = dt), do: {:ok, dt}
  defp to_datetime(%NaiveDateTime{} = ndt), do: {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
  defp to_datetime(%Date{} = d), do: {:ok, DateTime.new!(d, ~T[00:00:00], "Etc/UTC")}
  defp to_datetime(str) when is_binary(str), do: parse_datetime_string(str)
  defp to_datetime(_), do: :error

  # Parses a full datetime string, falling back to a date-only string
  # interpreted as midnight UTC. Returns `{:ok, %DateTime{}}` (UTC) or `:error`.
  defp parse_datetime_string(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      _ ->
        case Date.from_iso8601(str) do
          {:ok, d} -> {:ok, DateTime.new!(d, ~T[00:00:00], "Etc/UTC")}
          _ -> :error
        end
    end
  end

  # -- clock -----------------------------------------------------------------

  defp now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = dt -> dt
      _ -> clock(opts).()
    end
  end

  defp clock(opts) do
    case Zaq.Config.get(:zaq, __MODULE__, [], opts) do
      kw when is_list(kw) -> Keyword.get(kw, :clock, &DateTime.utc_now/0)
      _ -> &DateTime.utc_now/0
    end
  end

  # String-or-atom key lookup for JSONB-rehydrated (string) and in-memory (atom) maps.
  defp map_get(map, string_key) do
    case Map.fetch(map, string_key) do
      {:ok, v} -> v
      :error -> Map.get(map, safe_atom(string_key))
    end
  end

  defp safe_atom(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end
end
