defmodule Zaq.Channels.Web.ReadinessTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.Api
  alias Zaq.Channels.Web.{Readiness, Runtime}
  alias Zaq.Channels.WebBridge
  alias Zaq.Event

  defmodule Adapter do
    def status(id, timeout_ms: 2_000) do
      case id do
        1 -> {:ok, response()}
        2 -> {:ok, response(:unavailable, :transport_not_listening)}
        3 -> raise "secret-adapter-failure"
        4 -> {:ok, Map.put(response(), :token, "secret-adapter-failure")}
        5 -> Process.sleep(2_100)
      end
    end

    def response(status \\ :ready, reason \\ nil) do
      Zaq.WidgetReadinessFixtures.response(status, reason)
    end
  end

  defmodule Config do
    def get(:zaq, :channels, _), do: %{web_widget: %{adapter: Adapter}}
  end

  defmodule LegacyConfig do
    def get(:zaq, :channels, _), do: %{web_widget: %{adapter: __MODULE__}}
  end

  defmodule Resolver do
    def bridge_for("web_widget"), do: WebBridge
  end

  test "existing Channels event propagates runtime options into widget health" do
    event =
      Event.new(%{provider: "web_widget", config: config(1)}, :channels,
        opts: [config: Config, bridge_module: Resolver]
      )

    assert {:ok, %{status: :ok}} =
             Api.handle_event(event, :channel_ingress_status, %{}).response
  end

  test "both bridge ingress and runtime use verified transport health, not registry presence" do
    assert {:ok, %{status: :ok, summary: "Ready to receive connections"}} =
             WebBridge.channel_ingress_status(config(1), config: Config)

    assert {:ok, %{status: :error, reason: :transport_not_listening}} =
             Runtime.ingress_status(config(2), config: Config)
  end

  test "missing callback, exceptions and secret-bearing responses are unknown" do
    assert {:ok, %{status: :unknown, reason: :readiness_unsupported}} =
             Runtime.ingress_status(config(1), config: LegacyConfig)

    for id <- [3, 4] do
      assert {:ok, %{status: :unknown} = status} =
               Runtime.ingress_status(config(id), config: Config)

      refute inspect(status) =~ "secret-adapter-failure"
    end
  end

  test "adapter execution has a total timeout and disabled widgets are not probed" do
    assert {:ok, %{status: :unknown, reason: :check_timeout}} =
             Runtime.ingress_status(config(5), config: Config)

    assert {:ok, %{status: :disabled}} =
             Runtime.ingress_status(%{config(3) | enabled: false}, config: Config)

    assert {:error, :invalid_request} =
             Runtime.ingress_status(%{config(3) | provider: "web"}, config: Config)
  end

  test "unapplied desired settings invalidate otherwise ready health" do
    desired = Map.put(config(1), :settings, %{"identity_issuer" => "new_parent"})

    assert {:ok, %{status: :error, reason: :identity_settings_mismatch}} =
             Runtime.ingress_status(desired, config: Config)
  end

  test "closed schema rejects contradictory aggregation, invalid versions and unresolved readiness" do
    response = Adapter.response()

    for invalid <- [
          %{response | protocol_version: 2},
          %{response | status: :unknown},
          put_in(response.checks.transport.reason, :transport_not_listening),
          put_in(response.effective_settings.same_site, %{value: nil, source: :unresolved}),
          put_in(response.effective_settings.identity_issuer.source, :endpoint),
          put_in(response.effective_settings.same_site.value, "invalid"),
          put_in(response.checks.runtime, %{status: :ready, reason: nil, token: "private"}),
          put_in(response.effective_settings.identity_issuer, %{
            value: "issuer",
            source: :connector,
            key: "private"
          })
        ] do
      assert {:error, :invalid_readiness_response} = Readiness.validate(invalid)
    end
  end

  test "starting and unknown check states aggregate without claiming health" do
    assert {:ok, starting} = Readiness.validate(Adapter.response(:starting, :transport_starting))
    assert Readiness.project(starting, %{}).status == :pending

    unknown = Adapter.response(:unknown, :transport_unverifiable)
    assert {:ok, ^unknown} = Readiness.validate(unknown)
    assert Readiness.project(unknown, %{}).status == :unknown

    unavailable =
      unknown
      |> put_in([:checks, :delivery], %{status: :unavailable, reason: :pubsub_unavailable})
      |> Map.merge(%{status: :unavailable, reason: :pubsub_unavailable})

    assert {:ok, ^unavailable} = Readiness.validate(unavailable)
    assert Readiness.project(unavailable, %{}).status == :error
  end

  test "unverified cookie policy and legacy application values remain explicit" do
    response =
      Adapter.response()
      |> put_in([:checks, :cookie_policy], %{status: :unknown, reason: :cookie_policy_unsupported})
      |> put_in([:effective_settings, :same_site], %{value: nil, source: :unresolved})
      |> put_in([:effective_settings, :identity_issuer], %{
        value: "legacy_parent",
        source: :application
      })
      |> Map.merge(%{status: :unknown, reason: :cookie_policy_unsupported})

    assert {:ok, ^response} = Readiness.validate(response)
    health = Readiness.project(response, %{})
    assert health.status == :unknown
    assert health.effective_settings.identity_issuer.value == "legacy_parent"
    assert health.effective_settings.same_site.source == :unresolved
    assert Readiness.project(response, %{"same_site" => "None"}).status == :unknown
  end

  property "extra fields can never escape the adapter health boundary" do
    check all(value <- term()) do
      assert {:error, :invalid_readiness_response} =
               Readiness.validate(Map.put(Adapter.response(), :private_config, value))
    end
  end

  defp config(id), do: %{id: id, provider: "web_widget", enabled: true, settings: %{}}
end
