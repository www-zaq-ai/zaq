defmodule Zaq.Contracts.Materialization do
  @moduledoc """
  Where a record's bytes live, and how to reach them.

  A `Zaq.Contracts.Record` is a **handle**: it carries a file's identity and metadata and
  moves freely between nodes because it is small. This struct is the part that says where the
  bytes themselves are, so that `Zaq.Records.Materializer` can fetch them on demand.

  ## Direction-agnostic, on purpose

  "Where do these bytes live" is the same question before a read and after a write, so one
  struct is built to serve both verbs even though only the read verb exists today. A caller
  building a record to write would set a descriptor describing the *destination*; the owning
  role would fill in where it actually landed and return the same shape, which is then a
  perfectly ordinary source descriptor. The output of a write is the input of a read.

  Nothing here needs to change when that verb lands, which is the point of writing it this way
  now: the alternative — a read-shaped struct plus a write-shaped one — is two things to keep
  in sync and a conversion between them at exactly the boundary that must not drift.

  ## The fields

    * `role` — which node owns these bytes (`:ingestion`, `:channels`, `:agent`). The record
      routes itself: callers never name a role, and `Zaq.NodeRouter` routes on this alone —
      a descriptor saying `role: :channels` cannot arrive at ingestion at all.
    * `params` — everything the reader needs, and **opaque to everyone else**. The role that
      owns the bytes is the only code that may read a key out of it. That encapsulation is
      what lets storage layout change without touching a single caller.

      It is also the whole of the refusal: a reader matches the params it understands in its
      function head, and a descriptor whose params are shaped for other storage falls through
      to an error before any I/O. There is no separate discriminator field — one was tried,
      as a registry key and then as a tag, and in neither form did anything branch on it.
    * `as` — what the caller can *accept*: `:text` refuses non-UTF-8, `:binary` always
      base64-encodes, `:auto` detects. Note this is acceptance, not conversion — nobody can
      ask for a PNG "as text".
    * `max_bytes` — refuse before the bytes move rather than after. `nil` means no per-call
      cap; the `:transport_max_bytes` ceiling in `Zaq.Records.Limits` applies regardless.

  ## Never serialized

  This struct is deliberately **absent from `Record`'s `Jason.Encoder` derive list**, like
  `:raw`. It survives a node hop as an Erlang term but never renders into a tool result — so
  a locator, a bucket key or an adapter id reaches its owner without ever being shown to a
  model, which could otherwise read one and fabricate another back. `Zaq.Records.Materializer`
  and the M9.9 guard tests both depend on that property holding.

  ## Narrowing

  A caller may tighten `as` and `max_bytes` for its own consumption — see `narrow/2` — but
  never `role` or `params`. Those come from whoever minted the record, which is the role that
  owns the bytes.
  """

  @acceptance_modes [:auto, :text, :binary]

  @enforce_keys [:role]
  defstruct [:role, :max_bytes, params: %{}, as: :auto]

  @type acceptance :: :auto | :text | :binary

  @type t :: %__MODULE__{
          role: atom(),
          params: map(),
          as: acceptance(),
          max_bytes: pos_integer() | nil
        }

  @doc """
  Builds a descriptor.

  Raises `ArgumentError` on an unsupported `as` or a non-positive `max_bytes` — both are
  programmer errors in the minting code, not runtime conditions a caller could recover from.

      iex> Zaq.Contracts.Materialization.new(:ingestion).as
      :auto
  """
  @spec new(atom(), keyword()) :: t()
  def new(role, opts \\ []) when is_atom(role) do
    %__MODULE__{
      role: role,
      params: Keyword.get(opts, :params, %{}),
      as: opts |> Keyword.get(:as, :auto) |> validate_as!(),
      max_bytes: opts |> Keyword.get(:max_bytes) |> validate_max_bytes!()
    }
  end

  @doc """
  Tightens what the caller accepts, leaving the location alone.

  Only `:as` and `:max_bytes` are read from `opts`; `:role` and `:params` are ignored if
  passed. This is the type-level expression of the rule that a caller may say what it can
  handle but never where to look — a caller that could rewrite `params` could read or write
  anywhere its role can reach.

      iex> alias Zaq.Contracts.Materialization
      iex> d = Materialization.new(:ingestion, params: %{locator: "x"})
      iex> Materialization.narrow(d, as: :text, role: :channels) |> Map.take([:as, :role])
      %{as: :text, role: :ingestion}
  """
  @spec narrow(t(), keyword()) :: t()
  def narrow(%__MODULE__{} = materialization, opts) when is_list(opts) do
    %__MODULE__{
      materialization
      | as: opts |> Keyword.get(:as, materialization.as) |> validate_as!(),
        max_bytes:
          opts |> Keyword.get(:max_bytes, materialization.max_bytes) |> validate_max_bytes!()
    }
  end

  defp validate_as!(as) when as in @acceptance_modes, do: as

  defp validate_as!(as) do
    raise ArgumentError,
          "invalid :as #{inspect(as)} — expected one of #{inspect(@acceptance_modes)}"
  end

  defp validate_max_bytes!(nil), do: nil
  defp validate_max_bytes!(max) when is_integer(max) and max > 0, do: max

  defp validate_max_bytes!(max) do
    raise ArgumentError, "invalid :max_bytes #{inspect(max)} — expected a positive integer"
  end
end
