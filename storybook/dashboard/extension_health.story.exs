defmodule Storybook.Dashboard.ExtensionHealth do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  alias Zaq.Engine.Extension.Health
  alias ZaqWeb.Dashboard.ExtensionHealth

  def function, do: &ExtensionHealth.extension_health/1

  def variations do
    for status <- [:unconfigured, :checking, :healthy, :unreachable, :error] do
      %Variation{id: status, attributes: %{id: "extension-health-#{status}", health: %Health{status: status}}}
    end
  end
end
