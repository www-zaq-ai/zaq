defmodule ZaqWeb.Components.LiveUpdateSettingsTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Zaq.ConnectorConfig.LiveUpdates
  alias ZaqWeb.Components.LiveUpdateSettings

  test "fields explain throttling, expose exactly three triggers, and never create a form or save button" do
    html =
      render_component(&LiveUpdateSettings.fields/1,
        id: "stream-settings",
        policy: LiveUpdates.defaults()
      )

    assert html =~
             "When off, selected events can trigger updates without a minimum time interval."

    assert html =~ "Answer and reasoning text still use internal batching."
    assert html =~ "Progress/status messages are unaffected"
    assert html =~ "aria-describedby=\"stream-settings-frequency-help\""

    for trigger <- ~w(stream_delta reasoning tool_call) do
      assert html =~ "live_updates[triggers][#{trigger}]"
    end

    refute html =~ "live_updates[triggers][status]"
    refute html =~ "<form"
    refute html =~ "Save streamed updates"
    refute html =~ "buffer"
  end

  test "known LiveView usage markers are stripped but unknown keys still fail strict validation" do
    params = %{
      "_unused_enabled" => "",
      "enabled" => "true",
      "_unused_min_interval_ms" => "",
      "min_interval_ms" => "250",
      "triggers" => %{"_unused_reasoning" => "", "reasoning" => "false"}
    }

    draft = LiveUpdateSettings.merge_params(LiveUpdates.defaults(), params)
    assert {:ok, policy} = LiveUpdates.normalize_form(draft)
    assert policy["min_interval_ms"] == 250
    refute policy["triggers"]["reasoning"]
    refute inspect(policy) =~ "_unused_"
    refute LiveUpdateSettings.errors(Map.put(draft, "unrecognized", true)) == %{}
  end

  test "omitted disabled child controls retain draft preferences and invalid intervals remain errors" do
    draft =
      LiveUpdateSettings.merge_params(LiveUpdates.defaults(), %{
        "min_interval_ms" => "350",
        "triggers" => %{"tool_call" => "false"}
      })

    draft = LiveUpdateSettings.merge_params(draft, %{"enabled" => "false"})
    assert draft["min_interval_ms"] == "350"
    assert draft["triggers"]["tool_call"] == "false"
    assert LiveUpdateSettings.errors(draft) == %{}

    assert %{"min_interval_ms" => "must be a positive integer"} =
             LiveUpdateSettings.errors(Map.put(draft, "min_interval_ms", "0"))
  end

  test "unavailable settings render an error rather than editable defaults" do
    html =
      render_component(&LiveUpdateSettings.fields/1,
        id: "unavailable",
        load_error: "Unable to load streamed-update settings"
      )

    assert html =~ "Unable to load streamed-update settings"
    refute html =~ "name=\"live_updates[enabled]\""
  end

  test "malformed submitted triggers remain validation errors and can be corrected" do
    draft = LiveUpdateSettings.merge_params(LiveUpdates.defaults(), %{"triggers" => "invalid"})
    assert %{"triggers" => "must be a map"} = LiveUpdateSettings.errors(draft)

    assert render_component(&LiveUpdateSettings.fields/1,
             id: "invalid",
             policy: draft,
             errors: LiveUpdateSettings.errors(draft)
           ) =~ "must be a map"

    corrected = LiveUpdateSettings.merge_params(draft, %{"triggers" => %{"tool_call" => "false"}})
    assert LiveUpdateSettings.errors(corrected) == %{}
  end
end
