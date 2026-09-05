defmodule ZaqWeb.Components.DesignSystem.ModalUploadTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.UploadConfig
  alias ZaqWeb.Components.DesignSystem.ModalUpload

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

  # How SkillsLive configures the modal — every one of these is an opt-in; ingestion passes
  # none of them.
  defp render_modal(overrides) do
    defaults = [
      id: "skill-resource-modal",
      title: "Add resource",
      cancel_event: "close_resource_modal",
      uploads: uploads(),
      volumes: %{"documents" => "/vol/documents"},
      current_volume: "documents",
      volume_event: "select_resource_volume",
      destination: ".agents/skills/pricing-faq/references",
      upload_name: :skill_resources,
      id_prefix: "skill-resource",
      submit_event: "upload_skill_resource",
      change_event: "validate_skill_resource",
      file_cancel_event: "cancel_skill_resource",
      label: "Reference file",
      submit_label: "Add",
      hint: ".json .md .pdf .png — max 5.0 MB",
      folder_drop?: false
    ]

    render_component(
      &ModalUpload.modal_upload/1,
      Keyword.merge(defaults, overrides)
    )
  end

  defp ingestion_uploads do
    %{files: %{uploads().skill_resources | name: :files}}
  end

  describe "modal_upload/1 configured for skill resources" do
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

    test "passes through a browser accept override" do
      html = render_modal(input_accept: ".js,.lua,.rs")

      assert html =~ ~s(accept=".js,.lua,.rs")
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

    test "renders a footer Cancel wired to the cancel event" do
      html = render_modal([])

      assert html =~ ~s(phx-click="close_resource_modal")
      assert html =~ "Cancel"
      assert html =~ "zaq-modal-form-footer"
    end

    test "renders footer submit next to Cancel, disabled until a file is queued" do
      html = render_modal([])

      assert html =~ ~s(form="skill-resource-form")
      assert html =~ ~s(type="submit")
      assert html =~ "Add 0 file(s)"
      assert html =~ "disabled"
      assert html |> String.split("skill-resource-files-button") |> length() == 2
    end
  end

  describe "modal_upload/1 configured for workflow import" do
    defp workflow_uploads do
      %{
        workflow_file: %{
          uploads().skill_resources
          | name: :workflow_file,
            max_entries: 1,
            max_file_size: 1_000_000
        }
      }
    end

    defp render_workflow_modal(overrides \\ []) do
      defaults = [
        id: "import-modal",
        title: "Import Workflow",
        cancel_event: "close_import",
        uploads: workflow_uploads(),
        upload_name: :workflow_file,
        id_prefix: "workflow-import",
        submit_event: "import_workflow",
        change_event: "validate_import",
        file_cancel_event: "cancel_workflow_upload",
        label: "Workflow export file",
        submit_label: "Import",
        hint: ".json, .jsonc — max 1 MB",
        too_large_message: "File exceeds 1 MB limit.",
        folder_drop?: false,
        description: "Upload a .json or .jsonc workflow export file."
      ]

      render_component(
        &ModalUpload.modal_upload/1,
        Keyword.merge(defaults, overrides)
      )
    end

    test "renders the workflow-scoped dropzone ids and events" do
      html = render_workflow_modal()

      assert html =~ ~s(id="workflow-import-form")
      assert html =~ ~s(id="workflow-import-drop-zone")
      assert html =~ ~s(phx-submit="import_workflow")
      assert html =~ ~s(phx-change="validate_import")
      refute html =~ "FolderDrop"
    end

    test "shows description, hint and server-side error when given" do
      html =
        render_workflow_modal(error: "File is not valid JSON or JSONC.")

      assert html =~ "Upload a .json or .jsonc workflow export file."
      assert html =~ ".json, .jsonc — max 1 MB"
      assert html =~ "File is not valid JSON or JSONC."
    end

    test "renders footer Cancel wired to close_import" do
      html = render_workflow_modal()

      assert html =~ ~s(phx-click="close_import")
      assert html =~ "Cancel"
    end

    test "renders Import N file(s) submit in the footer, wired to the dropzone form" do
      html = render_workflow_modal()

      assert html =~ ~s(form="workflow-import-form")
      assert html =~ "Import 0 file(s)"
      assert html =~ "disabled"
    end
  end

  describe "modal_upload/1 defaults (ingestion)" do
    defp render_ingestion_modal(overrides \\ []) do
      render_component(
        &ModalUpload.modal_upload/1,
        Keyword.merge([uploads: ingestion_uploads()], overrides)
      )
    end

    test "renders the ingestion dropzone when nothing is configured" do
      html = render_ingestion_modal()

      assert html =~ ~s(id="upload-form")
      assert html =~ ~s(id="upload-drop-zone")
      assert html =~ ~s(phx-submit="upload")
      assert html =~ "Upload data"
      assert html =~ "FolderDrop"
    end

    test "hides the volume picker and destination preview" do
      html = render_ingestion_modal()

      # Both are skill-resources chrome. An ingestion caller passes neither, and adding the
      # options must not change what it renders.
      refute html =~ ~s(phx-change="select_volume")
      refute html =~ "Uploads to"
    end

    test "keeps the ingestion hint" do
      assert render_ingestion_modal() =~ ".docx"
    end

    test "renders a footer Cancel wired to the default cancel event" do
      html = render_ingestion_modal()

      assert html =~ ~s(phx-click="close_modal")
      assert html =~ "Cancel"
    end

    test "renders Upload N file(s) submit in the footer, disabled with an empty queue" do
      html = render_ingestion_modal()

      assert html =~ ~s(form="upload-form")
      assert html =~ ~s(id="upload-files-button")
      assert html =~ "Upload 0 file(s)"
      assert html =~ "disabled"
    end
  end

  describe "modal_no_volume/1" do
    test "renders the exact operator-facing message" do
      html = render_component(&ModalUpload.modal_no_volume/1, [])

      assert html =~ "Please, connect a volume to be able upload a resource"
      assert html =~ "No volume connected"
    end

    test "offers only an acknowledge action — nothing to confirm" do
      html = render_component(&ModalUpload.modal_no_volume/1, [])

      assert html =~ "Close"
      assert html =~ ~s(phx-click="close_resource_modal")
      refute html =~ "zaq-btn-danger"
      refute html =~ "hero-trash"
    end

    test "uses the warning badge, not the destructive one" do
      html = render_component(&ModalUpload.modal_no_volume/1, [])

      assert html =~ "zaq-modal-confirm-icon-badge--warning"
      assert html =~ "hero-exclamation-triangle"
    end

    test "accepts a custom cancel event and copy" do
      html =
        render_component(&ModalUpload.modal_no_volume/1,
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
