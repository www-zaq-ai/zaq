defmodule Zaq.Contracts.MaterializationTest do
  use ExUnit.Case, async: true

  alias Zaq.Contracts.Materialization
  alias Zaq.Contracts.Record

  # A locator that is realistic enough to grep for in encoded output. Every "must not leak"
  # assertion below scans for this exact string rather than for a key name, because what
  # matters is that the *value* never reaches a consumer, however it got there.
  @locator ".agents/skills/pricing-faq"

  defp descriptor(opts \\ []) do
    Materialization.new(
      :ingestion,
      :skill_bundle,
      Keyword.merge([params: %{locator: @locator, resource_path: "references/guide.md"}], opts)
    )
  end

  # The id is opaque on purpose. An id built by interpolating the locator would put it back
  # into the encoded output through a field that *is* in the derive list — undoing the whole
  # point of excluding the descriptor. Minting ids is M9.6's job; this is the shape it owes.
  defp record(opts \\ []) do
    %Record{
      id: "zaq_skill_bundle:g8Kx2mQ7fRt4vLpN",
      kind: :file,
      name: "guide.md",
      materialization: Keyword.get(opts, :materialization, descriptor()),
      raw: Keyword.get(opts, :raw, %{secret: @locator})
    }
  end

  describe "new/3" do
    test "defaults as: :auto, params: %{} and max_bytes: nil" do
      assert %Materialization{role: :ingestion, strategy: :skill_bundle} =
               materialization = Materialization.new(:ingestion, :skill_bundle)

      assert materialization.as == :auto
      assert materialization.params == %{}
      assert materialization.max_bytes == nil
    end

    test "accepts every supported acceptance mode" do
      for mode <- [:auto, :text, :binary] do
        assert %Materialization{as: ^mode} =
                 Materialization.new(:ingestion, :skill_bundle, as: mode)
      end
    end

    test "refuses an unsupported acceptance mode" do
      assert_raise ArgumentError, ~r/as/, fn ->
        Materialization.new(:ingestion, :skill_bundle, as: :yaml)
      end
    end

    test "refuses a non-positive max_bytes" do
      assert_raise ArgumentError, ~r/max_bytes/, fn ->
        Materialization.new(:ingestion, :skill_bundle, max_bytes: 0)
      end
    end
  end

  describe "narrow/2" do
    test "sets only the acceptance fields" do
      narrowed = descriptor() |> Materialization.narrow(as: :text, max_bytes: 1_024)

      assert narrowed.as == :text
      assert narrowed.max_bytes == 1_024
    end

    test "cannot change role, strategy or params" do
      original = descriptor()

      narrowed =
        Materialization.narrow(original,
          as: :text,
          role: :channels,
          strategy: :attachment,
          params: %{locator: "/etc"}
        )

      assert narrowed.role == original.role
      assert narrowed.strategy == original.strategy
      assert narrowed.params == original.params
    end

    test "leaves unmentioned acceptance fields untouched" do
      narrowed = descriptor(as: :binary, max_bytes: 99) |> Materialization.narrow(max_bytes: 10)

      assert narrowed.as == :binary
      assert narrowed.max_bytes == 10
    end

    test "validates like new/3" do
      assert_raise ArgumentError, ~r/as/, fn ->
        Materialization.narrow(descriptor(), as: :yaml)
      end
    end
  end

  describe "Record.materialization" do
    test "defaults to nil so existing consumers build unchanged" do
      assert %Record{materialization: nil} = %Record{id: "x", kind: :file}
    end

    test "holds a descriptor" do
      assert %Record{materialization: %Materialization{strategy: :skill_bundle}} = record()
    end
  end

  describe "JSON encoding" do
    # The whole design rests on this: descriptors cross nodes as Erlang terms but must never
    # render into a tool result, where a model could read a locator and fabricate one back.
    test "omits materialization and raw entirely" do
      encoded = record() |> Jason.encode!()

      refute encoded =~ "materialization"
      refute encoded =~ "raw"
      refute encoded =~ @locator
    end

    test "still encodes the fields a consumer needs" do
      encoded = record() |> Jason.encode!() |> Jason.decode!()

      assert encoded["name"] == "guide.md"
      assert encoded["kind"] == "file"
    end
  end

  describe "cross-node transfer" do
    test "survives an Erlang term round-trip with the descriptor intact" do
      original = record()
      restored = original |> :erlang.term_to_binary() |> :erlang.binary_to_term()

      assert restored.materialization == original.materialization
      assert restored.materialization.params.locator == @locator
    end
  end

  describe "persistence" do
    alias Zaq.Ingestion.RecordSource

    # A descriptor is a live routing handle, not durable state. Persisting a locator would
    # resurrect it after the file moved.
    test "to_storage_map/1 does not persist the descriptor" do
      stored = record() |> RecordSource.to_storage_map()

      refute Map.has_key?(stored, "materialization")
      refute stored |> Jason.encode!() =~ @locator
    end

    test "from_storage_map/1 yields a record with no descriptor" do
      {:ok, restored} =
        record() |> RecordSource.to_storage_map() |> RecordSource.from_storage_map()

      assert restored.materialization == nil
    end
  end
end
