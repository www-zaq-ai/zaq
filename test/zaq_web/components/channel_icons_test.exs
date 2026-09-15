defmodule ZaqWeb.Components.ChannelIconsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.ChannelIcons

  test "Slack viewport fits the logo rather than its original padded canvas" do
    html = render_component(&ChannelIcons.icon/1, provider: "slack")
    assert html =~ ~s(viewBox="73.6 73.6 122.8 122.8")
    assert html =~ ~s(class="w-6 h-6")
  end

  test "Slack preserves caller sizing for previews and headers" do
    for class <- ["w-3.5 h-3.5", "w-6 h-6"] do
      html = render_component(&ChannelIcons.icon/1, provider: "slack", class: class)

      assert html =~ ~s(class="#{class}")
    end
  end
end
