defmodule ZaqWeb.Live.BO.AI.SkillsLiveTest do
  use ZaqWeb.ConnCase

  import Ecto.Query
  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Agent.MCP
  alias Zaq.Agent.Skill
  alias Zaq.Agent.Skills
  alias Zaq.Agent.Skills.Limits
  alias Zaq.Ingestion.Document
  alias Zaq.Repo
  alias ZaqWeb.Helpers.SizeFormat
  alias ZaqWeb.Live.BO.AI.SkillsLive

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = user_fixture(%{username: "skills-admin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :services@localhost end)

    conn = init_test_session(conn, %{user_id: user.id})

    %{conn: conn}
  end

  defp create_skill!(attrs) do
    {:ok, skill} =
      %{
        body: "Instructions.",
        description: "What this skill does, and when to use it.",
        tool_keys: [],
        tags: []
      }
      |> Map.merge(attrs)
      |> Skills.create_skill()

    skill
  end

  defp with_skills_live_node_router(module) do
    previous = Application.get_env(:zaq, :skills_live_node_router_module)
    Application.put_env(:zaq, :skills_live_node_router_module, module)

    on_exit(fn ->
      if previous do
        Application.put_env(:zaq, :skills_live_node_router_module, previous)
      else
        Application.delete_env(:zaq, :skills_live_node_router_module)
      end
    end)
  end

  defmodule CreateFailureRouter do
    def dispatch(event), do: %{event | response: {:error, :create_failed}}
  end

  defmodule UpdateChangesetFailureRouter do
    def dispatch(event) do
      changeset =
        %Skill{}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:name, "is invalid")

      %{event | response: {:error, changeset}}
    end
  end

  defmodule DeleteFailureRouter do
    def dispatch(event), do: %{event | response: {:error, :delete_failed}}
  end

  # Routes events to the real modules instead of stubbing them: the point of the resource
  # tests is the LiveView → Channels → DiskBridge → Ingestion seam, so no hop under test is
  # faked. Only the transport is short-circuited — including the bridge's own inner hop,
  # which is re-entered through this same router.
  defmodule RealRouter do
    alias Zaq.Agent.Skills

    @datasource_actions [
      :data_source_create_file,
      :data_source_list_files,
      :data_source_get_file,
      :data_source_delete_file,
      :data_source_download_document
    ]

    @ingestion_actions [
      :materialize_record,
      :describe_records,
      :persist_record,
      :delete_record
    ]

    def dispatch(%{request: %{module: mod, function: fun, args: args}} = event) do
      %{event | response: apply(mod, fun, args)}
    end

    def dispatch(%{opts: opts} = event) do
      case Keyword.get(opts, :action) do
        action when action in @datasource_actions -> channels(event, action)
        action when action in @ingestion_actions -> ingestion(event, action)
        _ -> skills(event)
      end
    end

    # Re-inject this router so `DiskBridge`'s dispatch to ingestion comes back here rather
    # than reaching the real `NodeRouter`.
    defp channels(%{request: %{provider: provider, params: params}} = event, action) do
      request = %{provider: provider, params: Map.put(params, "node_router", __MODULE__)}

      Zaq.Channels.Api.handle_event(%{event | request: request}, action, nil)
    end

    defp ingestion(event, action), do: Zaq.Ingestion.Api.handle_event(event, action, nil)

    defp skills(%{request: %{id: id, attrs: attrs}} = event) do
      response =
        case Skills.update_skill(Skills.get_skill!(id), attrs) do
          {:ok, updated} -> {:ok, %{skill: updated}}
          {:error, changeset} -> {:error, changeset}
        end

      %{event | response: response}
    end

    # `:agent_skill_deleted` carries only an id. Must stay after the `attrs` clause above —
    # map patterns match on subsets, so this one would otherwise swallow updates too.
    defp skills(%{request: %{id: id}} = event) do
      {:ok, deleted} = Skills.delete_skill(Skills.get_skill!(id))
      %{event | response: {:ok, %{skill: deleted}}}
    end
  end

  # Writes fail, reads succeed — proves a failed upload records no reference.
  defmodule UploadFailureRouter do
    def dispatch(%{opts: opts} = event) do
      if Keyword.get(opts, :action) == :data_source_create_file do
        %{event | response: {:error, :eacces}}
      else
        RealRouter.dispatch(event)
      end
    end
  end

  # The ingestion node is unreachable, so `list_volumes` yields an error tuple instead of
  # the expected map.
  defmodule IngestionDownRouter do
    def dispatch(%{request: %{function: :list_volumes}} = event) do
      %{event | response: {:error, :node_down}}
    end

    def dispatch(%{request: %{function: :volumes_configured?}} = event) do
      %{event | response: {:error, :node_down}}
    end

    def dispatch(event), do: RealRouter.dispatch(event)
  end

  # Listing references fails — the ingestion role is unreachable behind the bridge.
  defmodule ListFailureRouter do
    def dispatch(%{opts: opts} = event) do
      if Keyword.get(opts, :action) == :data_source_list_files do
        %{event | response: {:error, :node_down}}
      else
        RealRouter.dispatch(event)
      end
    end
  end

  # Everything works except removing a resource file.
  defmodule ResourceDeleteFailureRouter do
    def dispatch(%{opts: opts} = event) do
      if Keyword.get(opts, :action) == :data_source_delete_file do
        %{event | response: {:error, :eperm}}
      else
        RealRouter.dispatch(event)
      end
    end
  end

  # Uploads succeed but recording the reference back onto the skill fails.
  defmodule SkillUpdateFailureRouter do
    def dispatch(%{request: %{module: _, function: _, args: _}} = event) do
      RealRouter.dispatch(event)
    end

    def dispatch(%{request: %{id: _, attrs: _}} = event) do
      %{event | response: {:error, :sync_failed}}
    end

    def dispatch(event), do: RealRouter.dispatch(event)
  end

  defp configure_volumes(volumes) do
    previous = Application.get_env(:zaq, Zaq.Ingestion)
    Application.put_env(:zaq, Zaq.Ingestion, base_path: "priv/documents", volumes: volumes)
    on_exit(fn -> Application.put_env(:zaq, Zaq.Ingestion, previous || []) end)
  end

  defp tmp_volume(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "skill_resources_#{name}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp open_skill(view, skill) do
    view |> element("[phx-click='select_skill'][phx-value-id='#{skill.id}']") |> render_click()
  end

  describe "skill resources — volume gate" do
    test "shows the connect-a-volume popup and no upload form when no volume is configured",
         %{conn: conn} do
      configure_volumes(%{})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "gated-skill"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)

      html = view |> element("#add-resource-button") |> render_click()

      assert html =~ "Please, connect a volume to be able upload a resource"
      assert has_element?(view, "#no-volume-modal")
      refute has_element?(view, "#skill-resource-form")
    end

    test "closes the no-volume popup", %{conn: conn} do
      configure_volumes(%{})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "gated-close"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      view |> element("#add-resource-button") |> render_click()

      view |> element("#no-volume-modal-close") |> render_click()

      refute has_element?(view, "#no-volume-modal")
    end

    test "opens the upload modal when a volume is connected", %{conn: conn} do
      configure_volumes(%{"documents" => tmp_volume("gate_ok")})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "gate-ok"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)

      html = view |> element("#add-resource-button") |> render_click()

      assert has_element?(view, "#skill-resource-form")
      refute has_element?(view, "#no-volume-modal")
      assert html =~ ".agents/skills/gate-ok/references"
    end
  end

  describe "skill resources — upload" do
    test "writes the file under .agents/skills/{name}/references and records the reference",
         %{conn: conn} do
      volume = tmp_volume("upload")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "pricing-faq"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      view |> element("#add-resource-button") |> render_click()

      upload =
        file_input(view, "#skill-resource-form", :skill_resources, [
          %{name: "prices.md", content: "# Prices", type: "text/markdown"}
        ])

      assert render_upload(upload, "prices.md")
      view |> form("#skill-resource-form") |> render_submit()

      assert File.exists?(Path.join(volume, ".agents/skills/pricing-faq/references/prices.md"))

      assert %{"references" => [%{"file_id" => file_id, "provider" => "disk"}]} =
               Skills.get_skill!(skill.id).resources

      # The reference points at a real document row, not a path.
      assert %Document{} = Document.get(String.to_integer(file_id))
    end

    # The rail that makes an agent able to read a skill file at all: `RecordMaterializer`
    # grants nothing implicitly, so an untagged document would be unreadable.
    test "tags the uploaded document public", %{conn: conn} do
      volume = tmp_volume("tagging")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "tagged-skill"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      view |> element("#add-resource-button") |> render_click()

      upload =
        file_input(view, "#skill-resource-form", :skill_resources, [
          %{name: "public.md", content: "x", type: "text/markdown"}
        ])

      assert render_upload(upload, "public.md")
      view |> form("#skill-resource-form") |> render_submit()

      %{"references" => [%{"file_id" => file_id}]} = Skills.get_skill!(skill.id).resources

      assert "public" in Document.get(String.to_integer(file_id)).tags
    end

    test "lists the uploaded file in the resources panel", %{conn: conn} do
      volume = tmp_volume("listing")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "listing-skill"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      view |> element("#add-resource-button") |> render_click()

      upload =
        file_input(view, "#skill-resource-form", :skill_resources, [
          %{name: "notes.md", content: "notes", type: "text/markdown"}
        ])

      assert render_upload(upload, "notes.md")
      html = view |> form("#skill-resource-form") |> render_submit()

      assert html =~ "notes.md"
      refute has_element?(view, "#skill-resource-modal")
    end

    test "writes into the volume the operator selected", %{conn: conn} do
      documents = tmp_volume("multi_docs")
      archives = tmp_volume("multi_arch")
      configure_volumes(%{"documents" => documents, "archives" => archives})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "multi-vol"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      view |> element("#add-resource-button") |> render_click()

      render_change(view, "select_resource_volume", %{"volume" => "documents"})

      upload =
        file_input(view, "#skill-resource-form", :skill_resources, [
          %{name: "picked.md", content: "picked", type: "text/markdown"}
        ])

      assert render_upload(upload, "picked.md")
      view |> form("#skill-resource-form") |> render_submit()

      assert File.exists?(Path.join(documents, ".agents/skills/multi-vol/references/picked.md"))
      refute File.exists?(Path.join(archives, ".agents/skills/multi-vol/references/picked.md"))
    end

    # A rename used to orphan files, which is why the old root was sticky. References are
    # document ids now, so files uploaded before a rename stay referenced wherever they sit,
    # and only new uploads follow the new name.
    test "a renamed skill keeps earlier references and writes new files under the new name",
         %{conn: conn} do
      volume = tmp_volume("rename")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "original-name"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      view |> element("#add-resource-button") |> render_click()

      upload =
        file_input(view, "#skill-resource-form", :skill_resources, [
          %{name: "before-rename.md", content: "x", type: "text/markdown"}
        ])

      assert render_upload(upload, "before-rename.md")
      view |> form("#skill-resource-form") |> render_submit()

      %{"references" => [%{"file_id" => original_id}]} = Skills.get_skill!(skill.id).resources

      {:ok, renamed} = Skills.update_skill(Skills.get_skill!(skill.id), %{name: "new-name"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, renamed)
      view |> element("#add-resource-button") |> render_click()

      upload =
        file_input(view, "#skill-resource-form", :skill_resources, [
          %{name: "after-rename.md", content: "x", type: "text/markdown"}
        ])

      assert render_upload(upload, "after-rename.md")
      view |> form("#skill-resource-form") |> render_submit()

      # New file follows the new name...
      assert File.exists?(Path.join(volume, ".agents/skills/new-name/references/after-rename.md"))

      # ...and the pre-rename file is still referenced, not stranded.
      references = Skills.get_skill!(skill.id).resources["references"]
      assert length(references) == 2
      assert Enum.any?(references, &(&1["file_id"] == original_id))
    end

    test "reports an upload failure and records no reference", %{conn: conn} do
      volume = tmp_volume("failure")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(UploadFailureRouter)
      skill = create_skill!(%{name: "failing-skill"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      view |> element("#add-resource-button") |> render_click()

      upload =
        file_input(view, "#skill-resource-form", :skill_resources, [
          %{name: "nope.md", content: "x", type: "text/markdown"}
        ])

      assert render_upload(upload, "nope.md")
      html = view |> form("#skill-resource-form") |> render_submit()

      assert html =~ "Upload failed"
      assert has_element?(view, "#skill-resource-modal")
      assert Skills.get_skill!(skill.id).resources == %{"references" => []}
    end

    test "reports the result in the overlay toast, not the BOLayout flash", %{conn: conn} do
      volume = tmp_volume("toast")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "toast-skill"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      view |> element("#add-resource-button") |> render_click()

      upload =
        file_input(view, "#skill-resource-form", :skill_resources, [
          %{name: "seen.md", content: "x", type: "text/markdown"}
        ])

      assert render_upload(upload, "seen.md")
      view |> form("#skill-resource-form") |> render_submit()

      # The drawer is open, so an inline BOLayout banner would render behind it. The toast
      # outranks the overlay — assert the message lands there and nowhere else.
      assert has_element?(view, "#resource-upload-toast", "1 resource(s) added.")
      refute has_element?(view, "#flash-info")
    end

    test "dismissing the toast clears it", %{conn: conn} do
      configure_volumes(%{"documents" => tmp_volume("toast_dismiss")})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "dismiss-skill"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      view |> element("#add-resource-button") |> render_click()

      upload =
        file_input(view, "#skill-resource-form", :skill_resources, [
          %{name: "gone.md", content: "x", type: "text/markdown"}
        ])

      assert render_upload(upload, "gone.md")
      view |> form("#skill-resource-form") |> render_submit()
      assert has_element?(view, "#resource-upload-toast")

      render_click(view, "dismiss_upload_toast", %{})

      refute has_element?(view, "#resource-upload-toast")
    end

    test "cancelling a queued entry removes it before submit", %{conn: conn} do
      configure_volumes(%{"documents" => tmp_volume("cancel")})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "cancel-skill"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      view |> element("#add-resource-button") |> render_click()

      upload =
        file_input(view, "#skill-resource-form", :skill_resources, [
          %{name: "discard.md", content: "x", type: "text/markdown"}
        ])

      render_upload(upload, "discard.md", 1)
      ref = upload.entries |> hd() |> Map.get("ref")

      render_hook(view, "cancel_skill_resource", %{"ref" => ref})

      # Assert on the upload config rather than the HTML: the filename also appears in
      # the live_file_input's own data attributes, so markup is not a reliable signal.
      state = :sys.get_state(view.pid)
      assert state.socket.assigns.uploads.skill_resources.entries == []
    end
  end

  describe "skill resources — degraded ingestion" do
    test "treats an unreachable ingestion node as no volumes, without crashing", %{conn: conn} do
      configure_volumes(%{"documents" => tmp_volume("down")})
      with_skills_live_node_router(IngestionDownRouter)
      skill = create_skill!(%{name: "down-skill"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)

      html = view |> element("#add-resource-button") |> render_click()

      # `list_volumes` returned an error tuple, not a map — the page degrades to the gate
      # rather than rendering an upload form it cannot service.
      assert html =~ "Please, connect a volume to be able upload a resource"
    end

    test "ignores a volume that is not configured", %{conn: conn} do
      volume = tmp_volume("unknown_vol")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "unknown-vol-skill"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      view |> element("#add-resource-button") |> render_click()

      render_change(view, "select_resource_volume", %{"volume" => "does-not-exist"})

      # The selection is refused, so the upload still targets the real volume.
      upload =
        file_input(view, "#skill-resource-form", :skill_resources, [
          %{name: "safe.md", content: "x", type: "text/markdown"}
        ])

      assert render_upload(upload, "safe.md")
      view |> form("#skill-resource-form") |> render_submit()

      assert File.exists?(
               Path.join(volume, ".agents/skills/unknown-vol-skill/references/safe.md")
             )
    end

    test "still reports the upload when recording the reference fails", %{conn: conn} do
      volume = tmp_volume("sync_fail")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(SkillUpdateFailureRouter)
      skill = create_skill!(%{name: "sync-fail-skill"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      view |> element("#add-resource-button") |> render_click()

      upload =
        file_input(view, "#skill-resource-form", :skill_resources, [
          %{name: "written.md", content: "x", type: "text/markdown"}
        ])

      assert render_upload(upload, "written.md")
      html = view |> form("#skill-resource-form") |> render_submit()

      # The file is on disk, so the operator must be told it succeeded even though the
      # bookkeeping write did not land.
      assert File.exists?(
               Path.join(volume, ".agents/skills/sync-fail-skill/references/written.md")
             )

      assert html =~ "1 resource(s) added."
      assert Skills.get_skill!(skill.id).resources == %{"references" => []}
    end
  end

  describe "skill resources — removing one" do
    defp upload_one!(view, filename) do
      view |> element("#add-resource-button") |> render_click()

      upload =
        file_input(view, "#skill-resource-form", :skill_resources, [
          %{name: filename, content: "x", type: "text/markdown"}
        ])

      assert render_upload(upload, filename)
      view |> form("#skill-resource-form") |> render_submit()
    end

    test "deletes the document and drops the reference", %{conn: conn} do
      volume = tmp_volume("remove_one")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "removable"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      upload_one!(view, "gone.md")

      %{"references" => [%{"file_id" => file_id}]} = Skills.get_skill!(skill.id).resources
      file = Path.join(volume, ".agents/skills/removable/references/gone.md")
      assert File.exists?(file)

      view
      |> element("[phx-click='remove_skill_resource'][phx-value-file_id='#{file_id}']")
      |> render_click()

      assert Skills.get_skill!(skill.id).resources == %{"references" => []}
      assert Document.get(String.to_integer(file_id)) == nil
      refute File.exists?(file)
    end

    test "keeps the reference when the delete fails", %{conn: conn} do
      volume = tmp_volume("remove_fail")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "stubborn"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      upload_one!(view, "stuck.md")

      %{"references" => [%{"file_id" => file_id}]} = Skills.get_skill!(skill.id).resources

      with_skills_live_node_router(ResourceDeleteFailureRouter)

      html =
        view
        |> element("[phx-click='remove_skill_resource'][phx-value-file_id='#{file_id}']")
        |> render_click()

      assert html =~ "Could not remove resource"
      assert %{"references" => [_]} = Skills.get_skill!(skill.id).resources
    end

    test "is a no-op when no skill is selected", %{conn: conn} do
      configure_volumes(%{"documents" => tmp_volume("remove_noskill")})
      with_skills_live_node_router(RealRouter)

      {:ok, view, _html} = live(conn, ~p"/bo/skills")

      assert render_click(view, "remove_skill_resource", %{"file_id" => "1"})
    end

    test "keeps the reference when recording its removal fails", %{conn: conn} do
      volume = tmp_volume("remove_sync_fail")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "sync-stubborn"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      upload_one!(view, "orphan.md")

      %{"references" => [%{"file_id" => file_id}]} = Skills.get_skill!(skill.id).resources

      # The file deletes, but writing the shortened reference list back does not.
      with_skills_live_node_router(SkillUpdateFailureRouter)

      html =
        view
        |> element("[phx-click='remove_skill_resource'][phx-value-file_id='#{file_id}']")
        |> render_click()

      assert html =~ "Could not remove resource"
    end

    # A reference row that predates the shape validation, or was hand-edited in the
    # database. It must be skipped, not crash the delete.
    test "skips a malformed reference on skill delete", %{conn: conn} do
      configure_volumes(%{"documents" => tmp_volume("malformed")})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "malformed-refs"})

      {:ok, _} =
        skill
        |> Ecto.Changeset.change(resources: %{"references" => [%{"file_id" => "1"}]})
        |> Repo.update()

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)

      html = view |> element("#delete-skill-button") |> render_click()

      assert html =~ "Skill deleted"
      refute html =~ "resources could not be removed"
    end

    test "renders no resources when the datasource is unreachable", %{conn: conn} do
      volume = tmp_volume("list_down")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "unlistable"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      upload_one!(view, "listed.md")

      with_skills_live_node_router(ListFailureRouter)

      html = open_skill(view, skill)

      # The page still renders; the panel is just empty.
      assert html =~ "No resources yet."
    end

    test "ignores a file_id the skill does not reference", %{conn: conn} do
      volume = tmp_volume("remove_absent")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "untouched"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      upload_one!(view, "kept.md")

      before = Skills.get_skill!(skill.id).resources

      render_click(view, "remove_skill_resource", %{"file_id" => "999999"})

      assert Skills.get_skill!(skill.id).resources == before
    end
  end

  describe "skill resources — cleanup on delete" do
    defp upload_resource!(view, filename) do
      view |> element("#add-resource-button") |> render_click()

      upload =
        file_input(view, "#skill-resource-form", :skill_resources, [
          %{name: filename, content: "x", type: "text/markdown"}
        ])

      assert render_upload(upload, filename)
      view |> form("#skill-resource-form") |> render_submit()
    end

    test "removes the skill's referenced files from the volume", %{conn: conn} do
      volume = tmp_volume("delete_res")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "doomed-skill"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      upload_resource!(view, "doomed.md")

      file = Path.join(volume, ".agents/skills/doomed-skill/references/doomed.md")
      assert File.exists?(file)

      view |> element("#delete-skill-button") |> render_click()

      refute File.exists?(file)
      assert Skills.get_skill(skill.id) == nil
    end

    # Deleting by id cannot reach past this skill's own references, which the old
    # directory sweep could not guarantee on a shared volume.
    test "leaves another skill's files alone", %{conn: conn} do
      volume = tmp_volume("delete_scope")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)
      doomed = create_skill!(%{name: "doomed-one"})
      neighbour = create_skill!(%{name: "neighbour-one"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, doomed)
      upload_resource!(view, "doomed.md")
      open_skill(view, neighbour)
      upload_resource!(view, "kept.md")

      kept = Path.join(volume, ".agents/skills/neighbour-one/references/kept.md")
      assert File.exists?(kept)

      open_skill(view, doomed)
      view |> element("#delete-skill-button") |> render_click()

      assert File.exists?(kept)
      assert Skills.get_skill(neighbour.id) != nil
    end

    test "removes the tracked document rows along with the files", %{conn: conn} do
      volume = tmp_volume("delete_docs")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "tracked-skill"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      upload_resource!(view, "tracked.md")

      assert Repo.aggregate(
               from(d in Document, where: like(d.source, "%tracked-skill%")),
               :count
             ) > 0

      view |> element("#delete-skill-button") |> render_click()

      assert Repo.aggregate(
               from(d in Document, where: like(d.source, "%tracked-skill%")),
               :count
             ) == 0
    end

    test "deletes a skill that never had resources without erroring", %{conn: conn} do
      volume = tmp_volume("delete_none")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "bare-skill"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)

      html = view |> element("#delete-skill-button") |> render_click()

      # No references, so nothing to delete — a no-op, not a surfaced error.
      assert html =~ "Skill deleted"
      refute html =~ "resources could not be removed"
      assert Skills.get_skill(skill.id) == nil
    end

    test "removes resources written to a non-default volume", %{conn: conn} do
      documents = tmp_volume("sweep_docs")
      archives = tmp_volume("sweep_arch")
      configure_volumes(%{"documents" => documents, "archives" => archives})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "swept-skill"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      render_change(view, "select_resource_volume", %{"volume" => "archives"})
      upload_resource!(view, "swept.md")

      archived = Path.join(archives, ".agents/skills/swept-skill/references/swept.md")
      assert File.exists?(archived)

      view |> element("#delete-skill-button") |> render_click()

      # The document id carries its own volume, so no sweep across volumes is needed.
      refute File.exists?(archived)
    end

    test "removes files uploaded before a rename", %{conn: conn} do
      volume = tmp_volume("delete_rename")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "before-rename"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      upload_resource!(view, "kept.md")

      {:ok, _} = Skills.update_skill(Skills.get_skill!(skill.id), %{name: "after-rename"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      view |> element("#delete-skill-button") |> render_click()

      # The reference is an id, so the rename is irrelevant to what gets removed.
      refute File.exists?(Path.join(volume, ".agents/skills/before-rename/references/kept.md"))
    end

    test "still deletes the skill when resource cleanup fails, and says so", %{conn: conn} do
      volume = tmp_volume("delete_fail")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "cleanup-fail"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)
      upload_resource!(view, "stuck.md")

      with_skills_live_node_router(ResourceDeleteFailureRouter)

      html = view |> element("#delete-skill-button") |> render_click()

      # The record deletion is the user's intent and already succeeded; orphaned files are
      # recoverable from the ingestion browser, so warn rather than pretend it all worked.
      assert html =~ "resources could not be removed"
      assert Skills.get_skill(skill.id) == nil
    end
  end

  describe "skill resources — staged upload on a new skill" do
    defp fill_new_skill(view, name) do
      view |> element("#new-skill-button") |> render_click()

      view
      |> form("#skill-form",
        skill: %{name: name, description: "Does the thing.", body: "Do the thing."}
      )
      |> render_change()
    end

    defp stage_resource!(view, filename) do
      view |> element("#add-resource-button") |> render_click()

      upload =
        file_input(view, "#skill-resource-form", :skill_resources, [
          %{name: filename, content: "staged", type: "text/markdown"}
        ])

      assert render_upload(upload, filename)
      view |> form("#skill-resource-form") |> render_submit()
    end

    defp submit_new_skill(view, name) do
      view
      |> form("#skill-form",
        skill: %{name: name, description: "Does the thing.", body: "Do the thing."}
      )
      |> render_submit()
    end

    test "accepts only json, md, pdf and png", %{conn: conn} do
      configure_volumes(%{"documents" => tmp_volume("accept_gate")})
      with_skills_live_node_router(RealRouter)

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      fill_new_skill(view, "picky-skill")
      view |> element("#add-resource-button") |> render_click()

      for filename <- ~w(notes.json notes.md notes.pdf notes.png) do
        upload =
          file_input(view, "#skill-resource-form", :skill_resources, [
            %{name: filename, content: "ok", type: "application/octet-stream"}
          ])

        assert render_upload(upload, filename)
      end

      # Formats ingestion accepts but a skill has no use for are refused client-side.
      for filename <- ~w(sheet.xlsx notes.txt deck.pptx) do
        upload =
          file_input(view, "#skill-resource-form", :skill_resources, [
            %{name: filename, content: "no", type: "application/octet-stream"}
          ])

        assert {:error, errors} = render_upload(upload, filename)
        assert Enum.all?(errors, &match?([_ref, :not_accepted], &1))
      end
    end

    test "refuses a file over the resource size cap", %{conn: conn} do
      configure_volumes(%{"documents" => tmp_volume("size_gate")})
      with_skills_live_node_router(RealRouter)

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      fill_new_skill(view, "heavy-skill")
      view |> element("#add-resource-button") |> render_click()

      # Nothing upstream caps a resource read — Jido's `load_resource/2` is an uncapped
      # `File.read/1` — so the ceiling is ours and it has to bite at upload time.
      cap = Limits.get(:resource_max_bytes)

      upload =
        file_input(view, "#skill-resource-form", :skill_resources, [
          %{name: "huge.md", content: String.duplicate("x", cap + 1), type: "text/markdown"}
        ])

      assert {:error, errors} = render_upload(upload, "huge.md")
      assert Enum.all?(errors, &match?([_ref, :too_large], &1))
    end

    test "advertises the enforced cap in the dropzone hint", %{conn: conn} do
      configure_volumes(%{"documents" => tmp_volume("hint")})
      with_skills_live_node_router(RealRouter)

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      fill_new_skill(view, "hinted-skill")
      html = view |> element("#add-resource-button") |> render_click()

      # The hint is derived from the same limit `allow_upload/3` uses, so it cannot promise
      # a cap the server will not honour.
      expected = SizeFormat.format_size(Limits.get(:resource_max_bytes))
      assert html =~ ".json .md .pdf .png"
      assert html =~ "max #{expected}"
    end

    test "hides the button until a name is typed", %{conn: conn} do
      configure_volumes(%{"documents" => tmp_volume("name_gate")})
      with_skills_live_node_router(RealRouter)

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      view |> element("#new-skill-button") |> render_click()

      refute has_element?(view, "#add-resource-button")

      fill_new_skill(view, "named-skill")

      # The destination is derivable from the name alone, so the action is real now.
      assert has_element?(view, "#add-resource-button")
    end

    test "keeps the button hidden when the name is only whitespace", %{conn: conn} do
      configure_volumes(%{"documents" => tmp_volume("blank_name")})
      with_skills_live_node_router(RealRouter)

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      fill_new_skill(view, "   ")

      refute has_element?(view, "#add-resource-button")
    end

    test "stages the file without writing to the volume before save", %{conn: conn} do
      volume = tmp_volume("staged")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      fill_new_skill(view, "staged-skill")
      stage_resource!(view, "later.md")

      # Nothing is on the volume yet — the skill does not exist, so neither does its home.
      refute File.exists?(Path.join(volume, ".agents/skills/staged-skill"))

      state = :sys.get_state(view.pid)
      assert length(state.socket.assigns.uploads.skill_resources.entries) == 1
    end

    test "shows a staged file as pending in the resources panel", %{conn: conn} do
      configure_volumes(%{"documents" => tmp_volume("staged_panel")})
      with_skills_live_node_router(RealRouter)

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      fill_new_skill(view, "pending-skill")
      html = stage_resource!(view, "pending.md")

      assert html =~ "pending.md"
      assert html =~ "Pending"
    end

    # The drawer closes on create, so the flash is the only report the operator gets.
    test "the create flash reports staged files that could not be written", %{conn: conn} do
      configure_volumes(%{"documents" => tmp_volume("staged_fail")})
      with_skills_live_node_router(UploadFailureRouter)

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      fill_new_skill(view, "staged-failure")
      stage_resource!(view, "doomed.md")

      html = submit_new_skill(view, "staged-failure")

      assert html =~ "Skill created with 0 resource(s)."
      assert html =~ "1 could not be uploaded."
    end

    test "writes staged files to the real destination when the skill is saved", %{conn: conn} do
      volume = tmp_volume("staged_save")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      fill_new_skill(view, "saved-with-res")
      stage_resource!(view, "arrived.md")

      submit_new_skill(view, "saved-with-res")

      assert File.exists?(
               Path.join(volume, ".agents/skills/saved-with-res/references/arrived.md")
             )

      skill = Skills.search_skills(%{q: "saved-with-res", tags: []}) |> hd()
      assert %{"references" => [%{"file_id" => _, "provider" => "disk"}]} = skill.resources
    end

    test "uses the name as saved, not the name at staging time", %{conn: conn} do
      volume = tmp_volume("staged_rename")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      fill_new_skill(view, "first-name")
      stage_resource!(view, "moved.md")

      # Renamed before saving — the destination is computed from the created record.
      submit_new_skill(view, "final-name")

      assert File.exists?(Path.join(volume, ".agents/skills/final-name/references/moved.md"))
      refute File.exists?(Path.join(volume, ".agents/skills/first-name"))
    end

    test "keeps files staged when the save fails validation", %{conn: conn} do
      volume = tmp_volume("staged_invalid")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      fill_new_skill(view, "valid-name")
      stage_resource!(view, "held.md")

      # Uppercase is rejected by the Open Agent Skills name format.
      submit_new_skill(view, "Not A Valid Name")

      refute File.exists?(Path.join(volume, ".agents/skills"))

      state = :sys.get_state(view.pid)
      assert length(state.socket.assigns.uploads.skill_resources.entries) == 1
    end

    test "does not leak a staged file into a different skill selected afterwards",
         %{conn: conn} do
      volume = tmp_volume("staged_leak")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)
      other = create_skill!(%{name: "innocent-skill"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      fill_new_skill(view, "abandoned-skill")
      stage_resource!(view, "orphan.md")

      # Walk away from the new skill by selecting an existing one, then upload there.
      open_skill(view, other)
      upload_resource!(view, "legit.md")

      innocent_dir = Path.join(volume, ".agents/skills/innocent-skill/references")
      assert File.exists?(Path.join(innocent_dir, "legit.md"))

      # The entry staged for the abandoned skill must not ride along into this one.
      refute File.exists?(Path.join(innocent_dir, "orphan.md"))
      refute File.exists?(Path.join(volume, ".agents/skills/abandoned-skill"))
    end

    test "does not leak a staged file into a second new skill", %{conn: conn} do
      volume = tmp_volume("staged_leak_new")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      fill_new_skill(view, "first-attempt")
      stage_resource!(view, "orphan.md")

      # Starting over must not carry the previous attempt's file into the new one.
      fill_new_skill(view, "second-attempt")
      submit_new_skill(view, "second-attempt")

      refute File.exists?(Path.join(volume, ".agents/skills/second-attempt/references/orphan.md"))
    end

    test "drops staged files when the form is cancelled", %{conn: conn} do
      volume = tmp_volume("staged_cancel")
      configure_volumes(%{"documents" => volume})
      with_skills_live_node_router(RealRouter)

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      fill_new_skill(view, "abandoned-skill")
      stage_resource!(view, "gone.md")

      view |> element("#close-skill-detail") |> render_click()

      state = :sys.get_state(view.pid)
      assert state.socket.assigns.uploads.skill_resources.entries == []
      refute File.exists?(Path.join(volume, ".agents/skills/abandoned-skill"))
    end
  end

  describe "skill resources — panel placement" do
    test "hides the add-resource button while creating a new skill", %{conn: conn} do
      configure_volumes(%{"documents" => tmp_volume("new_mode")})
      with_skills_live_node_router(RealRouter)

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      html = view |> element("#new-skill-button") |> render_click()

      # No name yet means no destination path, so the control is absent rather than
      # disabled — a disabled button reads as "temporarily off", which is misleading here.
      refute has_element?(view, "#add-resource-button")
      assert html =~ "Name the skill to add resources"
    end

    test "shows the add-resource button once the skill is saved", %{conn: conn} do
      configure_volumes(%{"documents" => tmp_volume("after_save")})
      with_skills_live_node_router(RealRouter)
      skill = create_skill!(%{name: "saved-skill"})

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      open_skill(view, skill)

      assert has_element?(view, "#add-resource-button")
    end

    test "the upload event is a no-op in :new mode", %{conn: conn} do
      configure_volumes(%{"documents" => tmp_volume("new_noop")})
      with_skills_live_node_router(RealRouter)

      {:ok, view, _html} = live(conn, ~p"/bo/skills")
      view |> element("#new-skill-button") |> render_click()

      # Defence in depth: the button is disabled, but the event must also refuse.
      assert render_click(view, "open_resource_upload", %{}) =~ "Skills"
      refute has_element?(view, "#skill-resource-modal")
      assert render_submit(view, "upload_skill_resource", %{}) =~ "Skills"
    end

    test "no resources panel when no skill is selected", %{conn: conn} do
      configure_volumes(%{"documents" => tmp_volume("idle")})
      with_skills_live_node_router(RealRouter)

      {:ok, _view, html} = live(conn, ~p"/bo/skills")

      refute html =~ "add-resource-button"
    end
  end

  test "renders skills page with empty state", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/bo/skills")

    assert html =~ "Skills"
    assert html =~ "Reusable instruction + tool bundles attachable to any agent"
    assert html =~ "No skills found."
    assert has_element?(view, "#new-skill-button")
    refute has_element?(view, "#skill-form-drawer")
  end

  test "lists existing skills with tags and status", %{conn: conn} do
    create_skill!(%{name: "listed-skill", tags: ["math"], description: "Does math"})
    create_skill!(%{name: "retired-skill", active: false})

    {:ok, _view, html} = live(conn, ~p"/bo/skills")

    assert html =~ "listed-skill"
    assert html =~ "Does math"
    assert html =~ "math"
    assert html =~ "retired-skill"
    assert html =~ "inactive"
  end

  test "filters skills by free text and tags", %{conn: conn} do
    create_skill!(%{name: "math-helper", tags: ["math"]})
    create_skill!(%{name: "web-search", tags: ["web"]})

    {:ok, view, _html} = live(conn, ~p"/bo/skills")

    html =
      view
      |> form("#skills-filter-form", filters: %{"q" => "math", "tag" => ""})
      |> render_change()

    assert html =~ "math-helper"
    refute html =~ "web-search"

    html =
      view
      |> form("#skills-filter-form", filters: %{"q" => "", "tag" => "web"})
      |> render_change()

    assert html =~ "web-search"
    refute html =~ "math-helper"
  end

  test "creates a skill from the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/skills")

    render_click(element(view, "#new-skill-button"))
    assert has_element?(view, "#skill-form-drawer")

    render_click(element(view, "#add-tools-button"))
    assert has_element?(view, "#skill-tools-picker-modal")

    render_change(view, "add_tool_from_picker", %{"tool_key" => "answering.search_knowledge_base"})

    view
    |> form("#skill-form",
      skill: %{
        "name" => "created-skill",
        "description" => "From the BO",
        "body" => "Do it well.",
        "tags" => "math, Utility",
        "active" => "true"
      }
    )
    |> render_submit()

    assert render(view) =~ "Skill created"
    refute has_element?(view, "#skill-form-drawer")

    assert [skill] = Skills.search_skills(%{q: "created-skill"})
    assert skill.tool_keys == ["answering.search_knowledge_base"]
    assert skill.tags == ["math", "utility"]
  end

  test "creates a skill with allowed_tools from the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/skills")

    render_click(element(view, "#new-skill-button"))

    view
    |> form("#skill-form",
      skill: %{
        "name" => "oas-skill",
        "description" => "Has OAS allowed tools",
        "body" => "Do it well.",
        # Space-separated OAS tool names, distinct from the ZAQ tool picker.
        "allowed_tools" => "Read Bash create_document",
        "tags" => "",
        "active" => "true"
      }
    )
    |> render_submit()

    assert render(view) =~ "Skill created"

    assert [skill] = Skills.search_skills(%{q: "oas-skill"})
    assert skill.allowed_tools == ["Read", "Bash", "create_document"]
    # allowed_tools is the OAS field and must NOT leak into ZAQ's provisioned tool keys.
    assert skill.provided_tool_keys == []
  end

  test "shows validation errors on invalid create", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/skills")

    render_click(element(view, "#new-skill-button"))

    html =
      view
      |> form("#skill-form",
        skill: %{
          "name" => "Bad Name",
          "description" => "What this skill does, and when to use it.",
          "body" => "b",
          "tags" => ""
        }
      )
      |> render_submit()

    assert html =~ "Invalid skill name"
    assert Skills.list_skills() == []
  end

  test "shows generic create failures from the agent router", %{conn: conn} do
    with_skills_live_node_router(CreateFailureRouter)

    {:ok, view, _html} = live(conn, ~p"/bo/skills")
    render_click(element(view, "#new-skill-button"))

    html =
      view
      |> form("#skill-form",
        skill: %{
          "name" => "router-create-failure",
          "description" => "What this skill does, and when to use it.",
          "body" => "Instructions.",
          "tags" => ""
        }
      )
      |> render_submit()

    assert html =~ "Failed to create skill: :create_failed"
  end

  test "edits an existing skill", %{conn: conn} do
    skill = create_skill!(%{name: "editable-skill", body: "Old."})

    {:ok, view, _html} = live(conn, ~p"/bo/skills")

    render_click(element(view, "#skill-row-#{skill.id}"))
    assert has_element?(view, "#skill-form-drawer")
    assert render(view) =~ "Edit Skill"

    view
    |> form("#skill-form",
      skill: %{
        "name" => "editable-skill",
        "description" => "What this skill does, and when to use it.",
        "body" => "New body.",
        "tags" => "updated",
        "active" => "true"
      }
    )
    |> render_submit()

    assert render(view) =~ "Skill saved"

    updated = Skills.get_skill!(skill.id)
    assert updated.body == "New body."
    assert updated.tags == ["updated"]
  end

  test "toggles the instructions markdown preview and renders the body", %{conn: conn} do
    skill = create_skill!(%{name: "previewable-skill", body: "# Heading\n\n- one\n- two"})

    {:ok, view, _html} = live(conn, ~p"/bo/skills")

    render_click(element(view, "#skill-row-#{skill.id}"))

    # Editing an existing skill opens in Preview mode: markdown rendered to HTML.
    # (The textarea stays mounted in both modes; the BO layout also renders an
    # <h1> page header, so key off the markdown-rendered heading content instead
    # of the bare <h1> tag.)
    assert has_element?(view, "#skill-body-input")
    html = render(view)
    assert html =~ "Heading</h1>"
    assert html =~ "<ul>"

    # Switch to Write: rendered preview gone, textarea still present.
    html = render_click(element(view, "button[phx-value-mode='write']"))
    refute html =~ "Heading</h1>"
    assert has_element?(view, "#skill-body-input")

    # Switch back to Preview: markdown is rendered again.
    html = render_click(element(view, "button[phx-value-mode='preview']"))
    assert html =~ "Heading</h1>"
    assert html =~ "<ul>"
  end

  test "preview reflects unsaved edits via validate", %{conn: conn} do
    skill = create_skill!(%{name: "live-preview-skill", body: "Old body."})

    {:ok, view, _html} = live(conn, ~p"/bo/skills")

    render_click(element(view, "#skill-row-#{skill.id}"))

    view
    |> form("#skill-form",
      skill: %{
        "name" => "live-preview-skill",
        "description" => "What this skill does, and when to use it.",
        "body" => "**bold draft**"
      }
    )
    |> render_change()

    html = render_click(element(view, "button[phx-value-mode='preview']"))
    assert html =~ "<strong>bold draft</strong>"
    refute html =~ "Old body."
  end

  test "preview shows a placeholder when the body is empty", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/skills")

    render_click(element(view, "#new-skill-button"))

    html = render_click(element(view, "button[phx-value-mode='preview']"))
    assert html =~ "Nothing to preview."
  end

  test "adds and removes tools via the picker", %{conn: conn} do
    skill = create_skill!(%{name: "toolable", tool_keys: ["answering.search_knowledge_base"]})

    {:ok, view, _html} = live(conn, ~p"/bo/skills")
    render_click(element(view, "#skill-row-#{skill.id}"))

    assert render(view) =~ "Search knowledge base"

    render_click(element(view, "#add-tools-button"))
    assert has_element?(view, "#skill-tools-picker-modal")
    render_change(view, "add_tool_from_picker", %{"tool_key" => "data_source.get_document"})

    view
    |> element(
      "#skill-tools-picker-modal button[phx-click=remove_tool][phx-value-key='answering.search_knowledge_base']"
    )
    |> render_click()

    view
    |> form("#skill-form",
      skill: %{
        "name" => "toolable",
        "description" => "What this skill does, and when to use it.",
        "body" => "Instructions.",
        "tags" => "",
        "active" => "true"
      }
    )
    |> render_submit()

    assert Skills.get_skill!(skill.id).tool_keys == ["data_source.get_document"]
  end

  test "tool picker closes and blank tool selection is ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/skills")

    render_click(element(view, "#new-skill-button"))
    render_click(element(view, "#add-tools-button"))
    assert has_element?(view, "#skill-tools-picker-modal")

    view
    |> element("#skill-tools-picker-modal button[phx-click='close_tools_picker']")
    |> render_click()

    refute has_element?(view, "#skill-tools-picker-modal")

    render_change(view, "add_tool_from_picker", %{"tool_key" => ""})

    view
    |> form("#skill-form",
      skill: %{
        "name" => "blank-tool-skill",
        "description" => "What this skill does, and when to use it.",
        "body" => "Instructions.",
        "active" => "true"
      }
    )
    |> render_submit()

    assert Skills.get_skill!(hd(Skills.search_skills(%{q: "blank-tool-skill"})).id).tool_keys ==
             []
  end

  test "adds and removes MCP endpoints via the picker", %{conn: conn} do
    {:ok, endpoint} =
      MCP.create_mcp_endpoint(%{
        name: "Skill MCP #{System.unique_integer([:positive])}",
        type: "remote",
        status: "enabled",
        timeout_ms: 5000,
        url: "http://localhost:8000/mcp"
      })

    {:ok, view, _html} = live(conn, ~p"/bo/skills")

    render_click(element(view, "#new-skill-button"))

    # picker button is enabled once endpoints exist, and the modal opens
    refute has_element?(view, "#add-mcp-button[disabled]")
    assert has_element?(view, "#add-mcp-button")

    render_change(view, "add_mcp_from_picker", %{"endpoint_id" => to_string(endpoint.id)})
    assert has_element?(view, ~s([data-selected-mcp-endpoint-id="#{endpoint.id}"]))

    view
    |> form("#skill-form",
      skill: %{
        "name" => "mcp-skill",
        "description" => "What this skill does, and when to use it.",
        "body" => "Instructions.",
        "tags" => "",
        "active" => "true"
      }
    )
    |> render_submit()

    assert render(view) =~ "Skill created"
    assert [skill] = Skills.search_skills(%{q: "mcp-skill"})
    assert skill.enabled_mcp_endpoint_ids == [endpoint.id]

    # remove it again from the selected panel and re-save
    render_click(element(view, "#skill-row-#{skill.id}"))

    view
    |> element(~s(button[phx-click="remove_mcp"][phx-value-id="#{endpoint.id}"]))
    |> render_click()

    view
    |> form("#skill-form",
      skill: %{
        "name" => "mcp-skill",
        "description" => "What this skill does, and when to use it.",
        "body" => "Instructions.",
        "tags" => "",
        "active" => "true"
      }
    )
    |> render_submit()

    assert Skills.get_skill!(skill.id).enabled_mcp_endpoint_ids == []
  end

  test "MCP picker closes and ignores blank or invalid endpoint ids", %{conn: conn} do
    {:ok, _endpoint} =
      MCP.create_mcp_endpoint(%{
        name: "Ignored MCP #{System.unique_integer([:positive])}",
        type: "remote",
        status: "enabled",
        timeout_ms: 5000,
        url: "http://localhost:8000/mcp"
      })

    {:ok, view, _html} = live(conn, ~p"/bo/skills")

    render_click(element(view, "#new-skill-button"))
    render_click(element(view, "#add-mcp-button"))
    assert has_element?(view, "#skill-mcp-picker-modal")

    view
    |> element("#skill-mcp-picker-modal button[phx-click='close_mcp_picker']")
    |> render_click()

    refute has_element?(view, "#skill-mcp-picker-modal")

    render_change(view, "add_mcp_from_picker", %{"endpoint_id" => ""})
    render_change(view, "add_mcp_from_picker", %{"endpoint_id" => "not-an-id"})
    refute has_element?(view, "[data-selected-mcp-endpoint-id]")

    view
    |> form("#skill-form",
      skill: %{
        "name" => "ignored-mcp-skill",
        "description" => "What this skill does, and when to use it.",
        "body" => "Instructions.",
        "active" => "true"
      }
    )
    |> render_submit()

    assert [skill] = Skills.search_skills(%{q: "ignored-mcp-skill"})
    assert skill.enabled_mcp_endpoint_ids == []
  end

  test "deletes a skill", %{conn: conn} do
    skill = create_skill!(%{name: "deletable-skill"})

    {:ok, view, _html} = live(conn, ~p"/bo/skills")

    render_click(element(view, "#skill-row-#{skill.id}"))
    render_click(element(view, "#delete-skill-button"))

    assert render(view) =~ "Skill deleted"
    assert Skills.get_skill(skill.id) == nil
  end

  test "stale skill selection shows not found", %{conn: conn} do
    skill = create_skill!(%{name: "stale-select-skill"})

    {:ok, view, _html} = live(conn, ~p"/bo/skills")
    {:ok, _deleted} = Skills.delete_skill(skill)

    html = render_click(view, "select_skill", %{"id" => to_string(skill.id)})

    assert html =~ "Skill not found"
    refute has_element?(view, "#skill-form-drawer")
  end

  test "validation handles list tags and saving without tags defaults to empty list", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/bo/skills")
    render_click(element(view, "#new-skill-button"))

    html =
      render_change(view, "validate", %{
        "skill" => %{
          "name" => "list-tags-skill",
          "description" => "What this skill does, and when to use it.",
          "body" => "Instructions.",
          "tags" => ["alpha", "beta"]
        }
      })

    assert html =~ "alpha, beta"

    render_click(element(view, "#close-skill-detail"))
    render_click(element(view, "#new-skill-button"))

    view
    |> form("#skill-form",
      skill: %{
        "name" => "untagged-skill",
        "description" => "What this skill does, and when to use it.",
        "body" => "Instructions.",
        "active" => "true"
      }
    )
    |> render_submit()

    assert [skill] = Skills.search_skills(%{q: "untagged-skill"})
    assert skill.tags == []
  end

  test "invalid edit keeps the existing skill unchanged", %{conn: conn} do
    skill = create_skill!(%{name: "invalid-edit-skill", body: "Original."})

    {:ok, view, _html} = live(conn, ~p"/bo/skills")
    render_click(element(view, "#skill-row-#{skill.id}"))

    html =
      view
      |> form("#skill-form",
        skill: %{
          "name" => "Invalid Name",
          "description" => "What this skill does, and when to use it.",
          "body" => "Changed.",
          "tags" => "",
          "active" => "true"
        }
      )
      |> render_submit()

    assert html =~ "Invalid skill name"
    assert Skills.get_skill!(skill.id).body == "Original."
    assert length(Skills.list_skills()) == 1
  end

  test "edit displays changeset errors returned by runtime sync", %{conn: conn} do
    with_skills_live_node_router(UpdateChangesetFailureRouter)
    skill = create_skill!(%{name: "router-edit-changeset", body: "Original."})

    {:ok, view, _html} = live(conn, ~p"/bo/skills")
    render_click(element(view, "#skill-row-#{skill.id}"))

    html =
      view
      |> form("#skill-form",
        skill: %{
          "name" => "router-edit-changeset",
          "description" => "What this skill does, and when to use it.",
          "body" => "Changed.",
          "tags" => "",
          "active" => "true"
        }
      )
      |> render_submit()

    assert html =~ "is invalid"
    assert Skills.get_skill!(skill.id).body == "Original."
  end

  test "raw events normalize defensive MCP endpoint and tag payloads" do
    {:ok, socket} = SkillsLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      SkillsLive.handle_event(
        "add_mcp_from_picker",
        %{"endpoint_id" => 123},
        socket
      )

    assert socket.assigns.form_mcp_endpoint_ids == [123]

    {:noreply, socket} =
      SkillsLive.handle_event(
        "remove_mcp",
        %{"id" => %{}},
        socket
      )

    assert socket.assigns.form_mcp_endpoint_ids == [123]

    {:noreply, socket} =
      SkillsLive.handle_event(
        "validate",
        %{
          "skill" => %{
            "name" => "raw-tags-skill",
            "description" => "What this skill does, and when to use it.",
            "body" => "Instructions.",
            "tags" => %{},
            "active" => true
          }
        },
        socket
      )

    assert socket.assigns.form[:tags].value == []

    {:noreply, socket} =
      SkillsLive.handle_event(
        "validate",
        %{
          "skill" => %{
            "name" => "raw-allowed-tools-skill",
            "description" => "What this skill does, and when to use it.",
            "body" => "Instructions.",
            "allowed_tools" => ["Read", "Bash"],
            "active" => true
          }
        },
        socket
      )

    assert socket.assigns.form[:allowed_tools].value == ["Read", "Bash"]

    {:noreply, socket} =
      SkillsLive.handle_event(
        "validate",
        %{
          "skill" => %{
            "name" => "raw-invalid-allowed-tools-skill",
            "description" => "What this skill does, and when to use it.",
            "body" => "Instructions.",
            "allowed_tools" => %{},
            "active" => true
          }
        },
        socket
      )

    assert socket.assigns.form[:allowed_tools].value == []
  end

  test "cancel hides the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/skills")

    render_click(element(view, "#new-skill-button"))
    assert has_element?(view, "#skill-form-drawer")

    render_click(element(view, "#close-skill-detail"))
    refute has_element?(view, "#skill-form-drawer")
  end

  test "delete shows router failures", %{conn: conn} do
    with_skills_live_node_router(DeleteFailureRouter)
    skill = create_skill!(%{name: "router-delete-failure"})

    {:ok, view, _html} = live(conn, ~p"/bo/skills")

    render_click(element(view, "#skill-row-#{skill.id}"))

    html = render_click(element(view, "#delete-skill-button"))

    assert html =~ "Failed to delete skill: :delete_failed"
    assert Skills.get_skill(skill.id)
  end
end
