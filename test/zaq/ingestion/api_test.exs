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
      assert [%{name: "pricing.md", resource_path: "references/pricing.md"}] = listing.references
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

    test ":read_skill_bundle_resource returns the file's text" do
      event = Event.new(%{bundle: @locator, resource: "references/pricing.md"}, :ingestion)
      result = Api.handle_event(event, :read_skill_bundle_resource, nil)

      assert result.response == {:ok, "# Pricing\n"}
    end

    test ":read_skill_bundle_resource surfaces the façade's error unchanged" do
      event = Event.new(%{bundle: @locator, resource: "references/absent.md"}, :ingestion)
      result = Api.handle_event(event, :read_skill_bundle_resource, nil)

      assert result.response == {:error, :not_found}
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
