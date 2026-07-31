defmodule Zaq.Ingestion.ApiTest do
  use ExUnit.Case, async: false

  alias Zaq.Event
  alias Zaq.Ingestion.Api

  @test_base "test/tmp/ingestion_api_bundle"
  @locator ".agents/skills/pricing-faq"

  test "delegates invoke to shared helper" do
    event = Event.new(%{module: String, function: :upcase, args: ["hi"]}, :ingestion)
    result = Api.handle_event(event, :invoke, nil)

    assert result.response == "HI"
  end

  test "returns unsupported action" do
    event = Event.new(%{module: String, function: :upcase, args: ["hi"]}, :ingestion)
    result = Api.handle_event(event, :unknown, nil)

    assert result.response == {:error, {:unsupported_action, :unknown}}
  end

  describe "record materialization actions" do
    alias Zaq.Contracts.Materialization
    alias Zaq.Contracts.Record

    defp record(strategy, params \\ %{}) do
      %Record{
        id: "r",
        kind: :file,
        materialization: Materialization.new(:ingestion, strategy, params: params)
      }
    end

    defp materialize(request),
      do: Api.handle_event(Event.new(request, :ingestion), :materialize_record, nil)

    defp persist(request),
      do: Api.handle_event(Event.new(request, :ingestion), :persist_record, nil)

    test ":materialize_record runs the record's strategy" do
      assert %{response: {:ok, %Record{content: "materialized"}}} =
               materialize(%{record: record(:test_read_write)})
    end

    test ":persist_record runs the record's strategy" do
      assert %{response: {:ok, %Record{}}} = persist(%{record: record(:test_read_write)})
      assert_received {:persisted, %Record{}, _opts}
    end

    # The clauses are strategy-agnostic; the registry is what decides whether this role runs
    # a given strategy, so an unknown one must not reach storage.
    test "an unregistered strategy is refused" do
      assert %{response: {:error, :unsupported_strategy}} =
               materialize(%{record: record(:not_registered)})
    end

    test "a verb the strategy did not declare is refused" do
      assert %{response: {:error, {:unsupported_verb, :persist}}} =
               persist(%{record: record(:test_read_only)})
    end

    test "invalid params are refused before the strategy runs" do
      assert %{response: {:error, :invalid_params}} =
               materialize(%{record: record(:test_read_write, %{ok: false})})

      refute_received {:materialized, _, _}
    end

    # A caller cannot name a bucket even by accident: only `:record` is matched, so anything
    # else in the request is inert.
    test "extra request keys such as :volume are inert" do
      assert %{response: {:ok, %Record{content: "materialized"}}} =
               materialize(%{record: record(:test_read_write), volume: "alpha"})
    end

    test "a record with no descriptor falls through to the default handler" do
      assert %{response: {:error, {:unsupported_action, :materialize_record}}} =
               materialize(%{record: %Record{id: "r", kind: :file}})
    end

    test "a bare map instead of a record falls through to the default handler" do
      assert %{response: {:error, {:unsupported_action, :materialize_record}}} =
               materialize(%{record: %{id: "r"}})
    end

    test "a request with no :record falls through to the default handler" do
      assert %{response: {:error, {:unsupported_action, :persist_record}}} = persist(%{})
    end
  end

  describe "skill bundle actions" do
    setup do
      File.rm_rf!(@test_base)
      alpha = Path.join(@test_base, "alpha")
      File.mkdir_p!(Path.join([alpha, @locator, "references"]))
      File.write!(Path.join([alpha, @locator, "references", "pricing.md"]), "# Pricing\n")

      original = Application.get_env(:zaq, Zaq.Ingestion)

      Application.put_env(:zaq, Zaq.Ingestion,
        base_path: @test_base,
        volumes: %{"alpha" => alpha}
      )

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.Ingestion, original || [])
        File.rm_rf!(@test_base)
      end)

      %{alpha: alpha}
    end

    test ":list_skill_bundle returns the façade's listing on the response" do
      event = Event.new(%{bundle: @locator}, :ingestion)
      result = Api.handle_event(event, :list_skill_bundle, nil)

      assert {:ok, listing} = result.response
      assert [%{name: "pricing.md", path: "references/pricing.md"}] = listing.references
    end

    test ":list_skill_bundle discloses no filesystem layout" do
      event = Event.new(%{bundle: @locator}, :ingestion)
      result = Api.handle_event(event, :list_skill_bundle, nil)

      assert {:ok, listing} = result.response
      serialized = inspect(listing)

      refute serialized =~ "absolute_path"
      refute serialized =~ "alpha"
      refute serialized =~ Path.expand(@test_base)
    end

    # Retired in favour of `:materialize_record`. Reading a file is a materialization like
    # any other, and the old action took a raw locator straight from its caller.
    test ":read_skill_bundle_resource is gone" do
      event = Event.new(%{bundle: @locator, resource: "references/pricing.md"}, :ingestion)
      result = Api.handle_event(event, :read_skill_bundle_resource, nil)

      assert result.response == {:error, {:unsupported_action, :read_skill_bundle_resource}}
    end

    test "a request missing :bundle falls through rather than crashing" do
      result = Api.handle_event(Event.new(%{}, :ingestion), :list_skill_bundle, nil)
      assert result.response == {:error, {:unsupported_action, :list_skill_bundle}}

      result =
        Api.handle_event(
          Event.new(%{resource: "references/a.md"}, :ingestion),
          :read_skill_bundle_resource,
          nil
        )

      assert result.response == {:error, {:unsupported_action, :read_skill_bundle_resource}}
    end

    test "a request missing :resource falls through rather than crashing" do
      result =
        Api.handle_event(
          Event.new(%{bundle: @locator}, :ingestion),
          :read_skill_bundle_resource,
          nil
        )

      assert result.response == {:error, {:unsupported_action, :read_skill_bundle_resource}}
    end

    test "a non-binary bundle falls through rather than crashing" do
      result = Api.handle_event(Event.new(%{bundle: 42}, :ingestion), :list_skill_bundle, nil)
      assert result.response == {:error, {:unsupported_action, :list_skill_bundle}}
    end

    test "a :volume key in the request is not honoured", %{alpha: alpha} do
      # A caller must not be able to name a bucket, even by accident. The extra key is
      # ignored: resolution still walks the configured volumes itself.
      decoy = Path.join(@test_base, "decoy")
      File.mkdir_p!(Path.join([decoy, @locator, "references"]))
      File.write!(Path.join([decoy, @locator, "references", "decoy.md"]), "wrong volume")

      event = Event.new(%{bundle: @locator, volume: "decoy"}, :ingestion)
      result = Api.handle_event(event, :list_skill_bundle, nil)

      assert {:ok, listing} = result.response
      assert [%{name: "pricing.md"}] = listing.references
      refute Enum.any?(listing.references, &(&1.name == "decoy.md"))

      # `decoy` is not even a configured volume — naming it changes nothing.
      assert Application.get_env(:zaq, Zaq.Ingestion)[:volumes] == %{"alpha" => alpha}
    end
  end
end
