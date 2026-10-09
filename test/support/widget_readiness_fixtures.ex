defmodule Zaq.WidgetReadinessFixtures do
  @moduledoc false

  def response(status \\ :ready, reason \\ nil) do
    %{
      protocol_version: 1,
      status: status,
      reason: reason,
      checks: %{
        runtime: %{status: :ready, reason: nil},
        transport: %{status: status, reason: reason},
        delivery: %{status: :ready, reason: nil},
        authentication: %{status: :ready, reason: nil},
        cookie_policy: %{status: :ready, reason: nil}
      },
      effective_settings: %{
        identity_issuer: %{value: "zaq_issuer", source: :connector},
        identity_audience: %{value: "zaq_audience", source: :connector},
        same_site: %{value: "None", source: :connector}
      }
    }
  end
end
