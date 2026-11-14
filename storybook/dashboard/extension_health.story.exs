defmodule Storybook.Dashboard.ExtensionHealth do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  alias Zaq.Engine.Extension.Health
  alias ZaqWeb.Dashboard.ExtensionHealth

  def function, do: &ExtensionHealth.extension_health/1

  def variations do
    for status <- [:unconfigured, :checking, :healthy, :unreachable, :error] do
      health = %Health{
        status: status,
        checked_at: if(status in [:healthy, :unreachable, :error], do: ~U[2026-11-14 08:00:00Z]),
        response_time_ms: if(status == :healthy, do: 42)
      }

      %Variation{id: status, attributes: %{id: "extension-health-#{status}", health: health}}
    end
  end
end
