defmodule Storybook.Components.Forms.ConnectionSettings do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.ConnectionSettings.editor/1

  def description do
    "Shared Main and Advanced settings composition using the People-style Toggle selector. Inactive controls stay in the parent form; " <>
      "the parent selects the first error tab after a rejected save, with Main taking priority."
  end

  def variations do
    [
      %Variation{
        id: :main_only,
        attributes: %{id: "simple-settings"},
        slots: [main_fields("main-only")]
      },
      %Variation{
        id: :main,
        attributes: %{id: "connection-main", active_tab: :main},
        slots: [main_fields("main"), advanced_fields("main")]
      },
      %Variation{
        id: :advanced,
        attributes: %{id: "connection-advanced", active_tab: :advanced},
        slots: [main_fields("advanced"), advanced_fields("advanced")]
      },
      %Variation{
        id: :both_tabs_invalid,
        attributes: %{
          id: "connection-errors",
          active_tab: :main,
          errors: %{main: true, advanced: true}
        },
        slots: [main_fields("errors"), advanced_fields("errors")]
      }
    ]
  end

  defp main_fields(prefix) do
    """
    <:main>
      <ZaqWeb.Components.DesignSystem.Input.input
        id="#{prefix}-name" name="connection[name]" label="Configuration name" value="Support workspace" />
    </:main>
    """
  end

  defp advanced_fields(prefix) do
    """
    <:advanced id="#{prefix}-streamed-section" label="Streamed message updates">
      <ZaqWeb.Components.LiveUpdateSettings.fields
        id="#{prefix}-streamed-fields" embedded={true}
        policy={Zaq.ConnectorConfig.LiveUpdates.defaults()} />
    </:advanced>
    <:advanced id="#{prefix}-file-section" label="File delivery">
      <ZaqWeb.Components.FileDeliverySettings.section
        id="#{prefix}-file-fields" name="connection[file_delivery]" heading={false}
        snapshot={%{resolved: %{file: :native}, file_delivery: %{limits: %{
          max_attachment_bytes: %{value: 5_000_000, configurable: true}
        }}}}
        settings={%{"max_attachment_bytes" => 1_000_001, "send_on_file_failure" => false}} />
    </:advanced>
    """
  end
end
