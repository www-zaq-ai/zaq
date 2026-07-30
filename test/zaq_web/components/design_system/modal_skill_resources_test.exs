defmodule ZaqWeb.Components.DesignSystem.ModalSkillResourcesTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.UploadConfig
  alias ZaqWeb.Components.DesignSystem.ModalNoVolume
  alias ZaqWeb.Components.DesignSystem.ModalSkillResources

  defp uploads do
    %{
      skill_resources: %UploadConfig{
        ref: "phx-upload-ref",
        entries: [],
        errors: [],
        name: :skill_resources,
        accept: :any,
        max_entries: 10,
        max_file_size: 20_000_000,
        chunk_size: 64_000,
        chunk_timeout: 10_000,
        external: false,
        auto_upload?: false,
        progress_event: nil
      }
    }
  end

  defp render_modal(overrides) do
    defaults = [
      uploads: uploads(),
      volumes: %{"documents" => "/vol/documents"},
      current_volume: "documents",
      destination: ".agents/skills/pricing-faq/references",
      hint: ".json .md .pdf .png — max 5.0 MB"
    ]

    render_component(
      &ModalSkillResources.modal_skill_resources/1,
      Keyword.merge(defaults, overrides)
    )
  end

  describe "modal_skill_resources/1" do
    test "renders the dropzone wired to the skill-scoped events and ids" do
      html = render_modal([])

      assert html =~ ~s(id="skill-resource-form")
      assert html =~ ~s(id="skill-resource-drop-zone")
      assert html =~ ~s(phx-submit="upload_skill_resource")
      assert html =~ ~s(phx-change="validate_skill_resource")
      assert html =~ "Add resource"
    end

    test "shows the caller's accepted formats and size cap" do
      html = render_modal(hint: ".json .md — max 1.0 MB")

      assert html =~ ".json .md — max 1.0 MB"
      refute html =~ ".docx"
    end

    test "does not attach the FolderDrop hook" do
      # Skill references are a flat directory — expanding dropped folders would create
      # nested paths the skill loader does not read.
      refute render_modal([]) =~ "FolderDrop"
    end

    test "shows the destination path so the operator can see where files land" do
      html = render_modal(destination: ".agents/skills/pricing-faq/references")

      assert html =~ ".agents/skills/pricing-faq/references"
    end

    test "hides the volume picker when only one volume is configured" do
      html = render_modal(volumes: %{"documents" => "/vol/documents"})

      refute html =~ ~s(phx-change="select_resource_volume")
    end

    test "renders the volume picker when several volumes are configured" do
      html =
        render_modal(
          volumes: %{"documents" => "/vol/documents", "archives" => "/vol/archives"},
          current_volume: "archives"
        )

      assert html =~ ~s(phx-change="select_resource_volume")
      assert html =~ "documents"
      assert html =~ "archives"
      assert html =~ "Volume"
    end

    test "marks the current volume as the selected value" do
      html =
        render_modal(
          volumes: %{"documents" => "/vol/documents", "archives" => "/vol/archives"},
          current_volume: "archives"
        )

      assert html =~ ~s(value="archives")
    end

    test "sorts volume options for a stable picker across renders" do
      html =
        render_modal(
          volumes: %{"zeta" => "/z", "alpha" => "/a", "mid" => "/m"},
          current_volume: "alpha"
        )

      # Map.keys/1 ordering is not guaranteed; the picker must not reshuffle between renders.
      alpha = :binary.match(html, "alpha") |> elem(0)
      mid = :binary.match(html, ~s(data-select-option="mid")) |> elem(0)
      zeta = :binary.match(html, ~s(data-select-option="zeta")) |> elem(0)

      assert alpha < mid
      assert mid < zeta
    end

    test "handles an empty volumes map without rendering a picker" do
      html = render_modal(volumes: %{}, current_volume: nil)

      refute html =~ ~s(phx-change="select_resource_volume")
    end
  end

  describe "modal_no_volume/1" do
    test "renders the exact operator-facing message" do
      html = render_component(&ModalNoVolume.modal_no_volume/1, [])

      assert html =~ "Please, connect a volume to be able upload a resource"
      assert html =~ "No volume connected"
    end

    test "offers only an acknowledge action — nothing to confirm" do
      html = render_component(&ModalNoVolume.modal_no_volume/1, [])

      assert html =~ "Close"
      assert html =~ ~s(phx-click="close_resource_modal")
      refute html =~ "zaq-btn-danger"
      refute html =~ "hero-trash"
    end

    test "uses the warning badge, not the destructive one" do
      html = render_component(&ModalNoVolume.modal_no_volume/1, [])

      assert html =~ "zaq-modal-confirm-icon-badge--warning"
      assert html =~ "hero-exclamation-triangle"
    end

    test "accepts a custom cancel event and copy" do
      html =
        render_component(&ModalNoVolume.modal_no_volume/1,
          cancel_event: "dismiss",
          title: "Nope",
          message: "No volume here",
          close_label: "Got it"
        )

      assert html =~ ~s(phx-click="dismiss")
      assert html =~ "Nope"
      assert html =~ "No volume here"
      assert html =~ "Got it"
    end
  end
end
