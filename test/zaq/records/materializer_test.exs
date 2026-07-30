defmodule Zaq.Records.MaterializerTest do
  use ExUnit.Case, async: true

  alias Zaq.Contracts.Materialization
  alias Zaq.Contracts.Record
  alias Zaq.Records.Content
  alias Zaq.Records.Materializer

  # A router that records what it was handed and replies with whatever the test set up. The
  # assertions that matter are about the *event* — which role, which action, which request —
  # because that is the contract the roles on the other side match on.
  defmodule Router do
    @moduledoc false
    def dispatch(event) do
      Process.put(:dispatched, event)
      %{event | response: Process.get(:response, {:ok, event.request.record})}
    end
  end

  defmodule RaisingRouter do
    @moduledoc false
    def dispatch(_event), do: raise("node down")
  end

  defmodule ExitingRouter do
    @moduledoc false
    def dispatch(_event), do: exit(:timeout)
  end

  defp respond(response), do: Process.put(:response, response)
  defp dispatched, do: Process.get(:dispatched)

  defp record(opts \\ []) do
    materialization =
      Keyword.get(
        opts,
        :materialization,
        Materialization.new(:ingestion, :skill_bundle, params: %{locator: ".agents/skills/faq"})
      )

    %Record{id: "r", kind: :file, name: "guide.md", materialization: materialization}
  end

  defp router_opts(extra \\ []), do: Keyword.merge([node_router: Router], extra)

  describe "materialize/2 routing" do
    test "dispatches to the role named on the record" do
      {:ok, _} = record() |> Materializer.materialize(router_opts())

      assert dispatched().next_hop.destination == :ingestion
      assert dispatched().opts[:action] == :materialize_record
    end

    # The role comes from the record, never from a default — this is what lets a channel
    # attachment and a skill resource travel the same code path.
    test "dispatches to a different role when the record says so" do
      channel_record =
        record(materialization: Materialization.new(:channels, :attachment, params: %{id: "a"}))

      {:ok, _} = Materializer.materialize(channel_record, router_opts())

      assert dispatched().next_hop.destination == :channels
    end

    test "sends exactly %{record: record} as the request" do
      subject = record()
      {:ok, _} = Materializer.materialize(subject, router_opts())

      assert Map.keys(dispatched().request) == [:record]
      assert dispatched().request.record.id == subject.id
    end

    test "refuses a record with no descriptor without dispatching" do
      assert {:error, :not_materializable} =
               %Record{id: "r", kind: :file} |> Materializer.materialize(router_opts())

      refute dispatched()
    end
  end

  describe "persist/2 routing" do
    test "dispatches the persist action to the record's role" do
      {:ok, record} = record() |> Content.put("hello", :auto)
      {:ok, _} = Materializer.persist(record, router_opts())

      assert dispatched().opts[:action] == :persist_record
      assert dispatched().next_hop.destination == :ingestion
    end

    test "refuses a record with no descriptor without dispatching" do
      assert {:error, :not_materializable} =
               %Record{id: "r", kind: :file} |> Materializer.persist(router_opts())

      refute dispatched()
    end
  end

  describe "opts may narrow acceptance only" do
    test "applies :as and :max_bytes to the dispatched descriptor" do
      {:ok, _} = record() |> Materializer.materialize(router_opts(as: :text, max_bytes: 1_024))

      assert dispatched().request.record.materialization.as == :text
      assert dispatched().request.record.materialization.max_bytes == 1_024
    end

    # A caller that could rewrite role, strategy or params could read or write anywhere its
    # role can reach. Those three come from whoever minted the record.
    test "ignores attempts to override role, strategy or params" do
      {:ok, _} =
        record()
        |> Materializer.materialize(
          router_opts(role: :channels, strategy: :attachment, params: %{locator: "/etc"})
        )

      descriptor = dispatched().request.record.materialization

      assert descriptor.role == :ingestion
      assert descriptor.strategy == :skill_bundle
      assert descriptor.params == %{locator: ".agents/skills/faq"}
      assert dispatched().next_hop.destination == :ingestion
    end
  end

  describe "transport ceiling" do
    setup do
      # 64 bytes, so the fixtures stay small and the intent stays obvious.
      %{opts: router_opts(limits_opts: [config: __MODULE__.Limits])}
    end

    defmodule Limits do
      @moduledoc false
      def get(:zaq, :records, _default, _opts), do: %{transport_max_bytes: 64}
      def get(app, key, default, _opts), do: Application.get_env(app, key, default)
    end

    test "caps the dispatched max_bytes so the far side refuses before reading", %{opts: opts} do
      {:ok, _} = record() |> Materializer.materialize(opts)

      assert dispatched().request.record.materialization.max_bytes == 64
    end

    test "never widens a caller's own tighter cap", %{opts: opts} do
      {:ok, _} = record() |> Materializer.materialize(Keyword.put(opts, :max_bytes, 16))

      assert dispatched().request.record.materialization.max_bytes == 16
    end

    test "refuses an oversize payload coming back from materialize", %{opts: opts} do
      {:ok, oversize} = record() |> Content.put(:binary.copy("a", 100), :auto)
      respond({:ok, oversize})

      assert {:error, {:too_large, 100}} = record() |> Materializer.materialize(opts)
    end

    test "refuses an oversize payload before persist dispatches it", %{opts: opts} do
      {:ok, oversize} = record() |> Content.put(:binary.copy("a", 100), :auto)

      assert {:error, {:too_large, 100}} = Materializer.persist(oversize, opts)
      refute dispatched()
    end

    test "measures raw bytes, not the base64 length", %{opts: opts} do
      # 60 raw bytes encodes to 80 base64 characters — over the 64-byte ceiling if you
      # measure the wrong thing.
      {:ok, record} = record() |> Content.put(:crypto.strong_rand_bytes(60), :binary)

      assert byte_size(record.content) > 64
      assert {:ok, _} = Materializer.persist(record, opts)
    end
  end

  describe "failure handling" do
    test "passes a strategy error through untouched" do
      respond({:error, :not_found})

      assert {:error, :not_found} = record() |> Materializer.materialize(router_opts())
    end

    test "a raising router reads as an error, not a crash" do
      assert {:error, {:raised, _}} =
               record() |> Materializer.materialize(node_router: RaisingRouter)
    end

    test "an exiting router reads as an error, not a crash" do
      assert {:error, {:exit, :timeout}} =
               record() |> Materializer.materialize(node_router: ExitingRouter)
    end

    test "an unexpected response shape reads as an error" do
      respond(:surprise)

      assert {:error, :unavailable} = record() |> Materializer.materialize(router_opts())
    end
  end
end
