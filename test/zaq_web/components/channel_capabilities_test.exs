defmodule ZaqWeb.Components.ChannelCapabilitiesTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Zaq.Channels.Api
  alias Zaq.Event
  alias ZaqWeb.Components.ChannelCapabilities

  for {provider, mode} <- [{"email:smtp", "none"}, {"email:imap", "imap_idle"}] do
    test "shared BO component displays #{provider} without provider-specific labels" do
      assert {:ok, email} = email_capability_snapshot(unquote(provider))

      html =
        render_component(&ChannelCapabilities.icon_with_modal/1,
          title: "Capabilities",
          modal_open?: true,
          snapshot: email
        )

      document = LazyHTML.from_fragment(html)

      supported_labels =
        document
        |> LazyHTML.query("#capabilities-modal li.text-emerald-700")
        |> Enum.map(&LazyHTML.text/1)
        |> Enum.map(&String.trim/1)

      assert supported_labels == ["Mode: " <> unquote(mode), "Text", "Threads"]
      assert document |> LazyHTML.query("#capabilities-modal li") |> LazyHTML.text() =~ "File"
      refute html =~ "receive only"
      refute html =~ "send only"
    end
  end

  describe "icon_with_modal/1" do
    test "failure is explicit and hides any stale capabilities" do
      html =
        render_component(&ChannelCapabilities.icon_with_modal/1,
          modal_open?: true,
          title: "Unavailable channel",
          error?: true,
          snapshot: %{required: [:text], resolved: %{text: :native}, labels: %{text: "Text"}}
        )

      assert html =~ "Capabilities unavailable"
      refute html =~ "text-emerald-700"
      assert html =~ "channel-capabilities-close"
    end

    test "successful empty snapshots remain distinct from failures" do
      for options <- [[], [error?: false]] do
        html =
          render_component(
            &ChannelCapabilities.icon_with_modal/1,
            [modal_open?: true, title: "Empty channel", snapshot: %{}] ++ options
          )

        refute html =~ "Capabilities unavailable"
        assert html =~ "Empty channel"
      end
    end

    test "modal closed state: only button renders, no modal" do
      html =
        render_component(&ChannelCapabilities.icon_with_modal/1,
          modal_open?: false,
          title: "Test Channel",
          snapshot: %{}
        )

      assert html =~ "Show capabilities"
      refute html =~ "capabilities-modal"
      refute html =~ "phx-click=\"close_capabilities\""
    end

    test "modal open with empty snapshot: modal shows title but no capabilities" do
      html =
        render_component(&ChannelCapabilities.icon_with_modal/1,
          modal_open?: true,
          title: "Empty Channel",
          snapshot: %{}
        )

      assert html =~ "capabilities-modal"
      assert html =~ "Empty Channel"
      refute html =~ "text-emerald-700"
    end

    test "renders supported and unsupported capabilities with correct styling" do
      html =
        render_component(&ChannelCapabilities.icon_with_modal/1,
          modal_open?: true,
          title: "Test Channel",
          snapshot: %{
            labels: %{read: "Read Messages", write: "Write Messages"},
            required: [:read, :write],
            resolved: %{read: true, write: false}
          }
        )

      assert html =~ "Read Messages"
      assert html =~ "Write Messages"
      assert html =~ "text-emerald-700"
      assert html =~ "text-black/40"
    end

    test "mode capability with atom key and non-empty value shows label: value" do
      html =
        render_component(&ChannelCapabilities.icon_with_modal/1,
          modal_open?: true,
          title: "Test Channel",
          snapshot: %{
            labels: %{mode: "Mode"},
            required: [:mode],
            resolved: %{mode: "assistant"}
          }
        )

      assert html =~ "Mode: assistant"
    end

    test "mode capability with string key and non-empty value shows label: value" do
      html =
        render_component(&ChannelCapabilities.icon_with_modal/1,
          modal_open?: true,
          title: "Test Channel",
          snapshot: %{
            labels: %{"mode" => "Mode"},
            required: ["mode"],
            resolved: %{"mode" => "user"}
          }
        )

      assert html =~ "Mode: user"
    end

    test "mode capability with empty string value shows label only" do
      html =
        render_component(&ChannelCapabilities.icon_with_modal/1,
          modal_open?: true,
          title: "Test Channel",
          snapshot: %{
            labels: %{mode: "Mode"},
            required: [:mode],
            resolved: %{mode: ""}
          }
        )

      assert html =~ "Mode"
      refute html =~ "Mode:"
    end

    test "mode capability with nil value shows label only" do
      html =
        render_component(&ChannelCapabilities.icon_with_modal/1,
          modal_open?: true,
          title: "Test Channel",
          snapshot: %{
            labels: %{mode: "Mode"},
            required: [:mode],
            resolved: %{mode: nil}
          }
        )

      assert html =~ "Mode"
      refute html =~ "Mode:"
    end

    test "non-mode capability displays label only without value suffix" do
      html =
        render_component(&ChannelCapabilities.icon_with_modal/1,
          modal_open?: true,
          title: "Test Channel",
          snapshot: %{
            labels: %{read: "Read"},
            required: [:read],
            resolved: %{read: true}
          }
        )

      assert html =~ "Read"
    end

    test "resolves value using atom key in resolved map" do
      html =
        render_component(&ChannelCapabilities.icon_with_modal/1,
          modal_open?: true,
          title: "Test Channel",
          snapshot: %{
            labels: %{read: "Read"},
            required: [:read],
            resolved: %{read: true}
          }
        )

      assert html =~ "text-emerald-700"
    end

    test "falls back to string key when atom key not found in resolved map" do
      html =
        render_component(&ChannelCapabilities.icon_with_modal/1,
          modal_open?: true,
          title: "Test Channel",
          snapshot: %{
            labels: %{read: "Read"},
            required: [:read],
            resolved: %{"read" => true}
          }
        )

      assert html =~ "text-emerald-700"
    end

    test "uses custom label from labels map" do
      html =
        render_component(&ChannelCapabilities.icon_with_modal/1,
          modal_open?: true,
          title: "Test Channel",
          snapshot: %{
            labels: %{write: "Write Messages"},
            required: [:write],
            resolved: %{write: true}
          }
        )

      assert html =~ "Write Messages"
    end

    test "falls back to capability atom name when label not in labels map" do
      html =
        render_component(&ChannelCapabilities.icon_with_modal/1,
          modal_open?: true,
          title: "Test Channel",
          snapshot: %{
            required: [:custom_feature],
            resolved: %{custom_feature: true}
          }
        )

      assert html =~ "custom_feature"
    end

    test "capabilities are sorted alphabetically by label (case-insensitive)" do
      html =
        render_component(&ChannelCapabilities.icon_with_modal/1,
          modal_open?: true,
          title: "Test Channel",
          snapshot: %{
            labels: %{z: "Zulu", a: "Alpha", m: "Mike"},
            required: [:z, :a, :m],
            resolved: %{z: true, a: true, m: true}
          }
        )

      alpha_index = String.split(html, "Alpha") |> List.first() |> String.length()
      mike_index = String.split(html, "Mike") |> List.first() |> String.length()
      zulu_index = String.split(html, "Zulu") |> List.first() |> String.length()

      assert alpha_index < mike_index, "Alpha should appear before Mike"
      assert mike_index < zulu_index, "Mike should appear before Zulu"
    end
  end

  defp email_capability_snapshot(provider) do
    event =
      Event.new(%{provider: provider, scope: :provider}, :channels,
        opts: [action: :channel_capability_snapshot]
      )

    Api.handle_event(event, :channel_capability_snapshot, nil).response
  end
end
