defmodule ZaqWeb.Live.BO.Data.LabelsLiveTest do
  use ZaqWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  alias Zaq.Ingestion.{Document, Labels}
  alias Zaq.Ingestion.Labels.Assignment
  alias Zaq.Repo

  describe "catalog management" do
    setup %{conn: conn} do
      user = super_admin_fixture(%{must_change_password: false})
      %{conn: init_test_session(conn, %{user_id: user.id}), actor: %{user_id: user.id}}
    end

    test "selection styles update every streamed row and row click opens editing", %{
      conn: conn,
      actor: actor
    } do
      labels =
        for name <- ["First", "Second"] do
          {:ok, label} = Labels.save_definition(%{name: name, resources: ["document"]}, actor)
          label
        end

      {:ok, view, _} = live(conn, ~p"/bo/labels")
      assert has_element?(view, "#labels-table.zaq-border-default")
      refute has_element?(view, "#labels-table button", "Edit")
      assert has_element?(view, ".hidden > #delete-selected-labels")
      view |> element("#select-all-labels") |> render_click()
      refute has_element?(view, ".hidden > #delete-selected-labels")

      for label <- labels do
        assert has_element?(view, "input[phx-value-id='#{label.id}'][checked]")
        assert has_element?(view, "#labels-#{label.id}.zaq-table-row--selected")
      end

      view |> element("#select-all-labels") |> render_click()
      refute has_element?(view, "#labels input[checked]")
      assert has_element?(view, ".hidden > #delete-selected-labels")

      for label <- labels,
          do: refute(has_element?(view, "#labels-#{label.id}.zaq-table-row--selected"))

      label = hd(labels)
      view |> element("input[phx-value-id='#{label.id}']") |> render_click()
      assert has_element?(view, "input[phx-value-id='#{label.id}'][checked]")

      assert has_element?(
               view,
               "#delete-selected-labels.zaq-btn-tertiary.zaq-btn-danger",
               "Delete (1)"
             )

      refute has_element?(view, "#label-definition-modal")

      assert has_element?(
               view,
               "#labels-#{label.id} .zaq-table-actions--reveal-hover button[phx-click=request_delete_label]"
             )

      view |> element("#labels-#{label.id}") |> render_click()
      assert has_element?(view, "#label-definition-modal")
    end

    test "bulk selection toggles, clears on search and confirms the whole batch", %{
      conn: conn,
      actor: actor
    } do
      {:ok, first} = Labels.save_definition(%{name: "Bulk first", resources: ["document"]}, actor)

      {:ok, second} =
        Labels.save_definition(%{name: "Bulk second", resources: ["document"]}, actor)

      {:ok, view, _} = live(conn, ~p"/bo/labels")
      assert has_element?(view, "#delete-selected-labels[disabled]")

      view
      |> element("input[phx-click=toggle_label_selection][phx-value-id='#{first.id}']")
      |> render_click()

      assert has_element?(view, "#delete-selected-labels", "(1)")
      view |> element("#select-all-labels") |> render_click()
      assert has_element?(view, "#delete-selected-labels", "(2)")
      assert has_element?(view, "#select-all-labels[checked]")
      view |> element("#select-all-labels") |> render_click()
      assert has_element?(view, "#delete-selected-labels[disabled]")
      view |> element("#select-all-labels") |> render_click()
      view |> form("#labels-search-form", query: "first") |> render_change()
      assert has_element?(view, "#delete-selected-labels[disabled]")
      view |> form("#labels-search-form", query: "") |> render_change()
      view |> element("#select-all-labels") |> render_click()
      view |> element("#delete-selected-labels") |> render_click()
      assert has_element?(view, "#bulk-delete-labels-confirmation", "Bulk first")
      assert has_element?(view, "#bulk-delete-labels-confirmation", "Bulk second")
      view |> element("button[phx-click=cancel_bulk_delete]", "Cancel") |> render_click()
      assert {:ok, [_, _]} = Labels.list(actor)
      view |> element("#delete-selected-labels") |> render_click()
      {:ok, document} = Document.create(%{source: "bulk-ui"})

      assert {:ok, _} =
               Labels.edit_resource(
                 %{type: "document", id: document.id},
                 [%{label_id: second.id, operation: "add", expected_version: 0, value: true}],
                 actor
               )

      view |> element("#confirm-bulk-delete-labels") |> render_click()
      assert has_element?(view, "#bulk-delete-labels-confirmation", "confirm again")
      assert has_element?(view, "#bulk-delete-labels-confirmation", "1 document(s)")
      assert {:ok, [_, _]} = Labels.list(actor)
      view |> element("#confirm-bulk-delete-labels") |> render_click()
      assert {:ok, []} = Labels.list(actor)
      assert has_element?(view, "#delete-selected-labels[disabled]")
    end

    test "bulk deletion refreshes selection if another administrator deletes a label", %{
      conn: conn,
      actor: actor
    } do
      {:ok, first} = Labels.save_definition(%{name: "Keep", resources: ["document"]}, actor)
      {:ok, second} = Labels.save_definition(%{name: "Gone", resources: ["document"]}, actor)
      {:ok, view, _} = live(conn, ~p"/bo/labels")
      view |> element("#select-all-labels") |> render_click()
      view |> element("#delete-selected-labels") |> render_click()
      {:ok, preview} = Labels.deletion_preview(second.id, actor)

      assert {:ok, _} =
               Labels.delete_definition(
                 %{
                   id: second.id,
                   expected_version: preview.expected_version,
                   expected_usage: preview.usage
                 },
                 actor
               )

      view |> element("#confirm-bulk-delete-labels") |> render_click()
      refute has_element?(view, "#bulk-delete-labels-confirmation")
      assert has_element?(view, "#delete-selected-labels[disabled]")
      assert {:ok, [%{id: id}]} = Labels.list(actor)
      assert id == first.id
    end

    test "staff cannot select labels or request bulk deletion", %{conn: conn, actor: actor} do
      {:ok, label} = Labels.save_definition(%{name: "Protected", resources: ["document"]}, actor)
      user = staff_fixture(%{must_change_password: false})
      {:ok, view, _} = live(init_test_session(conn, %{user_id: user.id}), ~p"/bo/labels")
      refute has_element?(view, "#select-all-labels")
      refute has_element?(view, "#delete-selected-labels")
      render_click(view, "toggle_label_selection", %{"id" => to_string(label.id)})
      render_click(view, "select_all_labels", %{})
      render_click(view, "request_bulk_delete", %{})
      refute has_element?(view, "#bulk-delete-labels-confirmation")
      assert {:error, :forbidden} = Labels.bulk_deletion_preview([label.id], %{user_id: user.id})
    end

    test "table deletion confirms usage changes and preserves the document", %{
      conn: conn,
      actor: actor
    } do
      {:ok, label} =
        Labels.save_definition(%{name: "Delete category", resources: ["document"]}, actor)

      {:ok, document} = Document.create(%{source: "delete-ui"})
      {:ok, view, _} = live(conn, ~p"/bo/labels")

      view
      |> element("button[phx-click=request_delete_label][phx-value-id='#{label.id}']")
      |> render_click()

      assert has_element?(view, "#delete-label-confirmation", "not assigned")

      assert {:ok, _} =
               Labels.edit_resource(
                 %{type: "document", id: document.id},
                 [%{label_id: label.id, operation: "add", expected_version: 0, value: true}],
                 actor
               )

      view |> element("#confirm-delete-label") |> render_click()
      assert has_element?(view, "#delete-label-confirmation", "Label usage changed")
      assert has_element?(view, "#delete-label-confirmation", "1 document(s)")
      assert {:ok, [_]} = Labels.list(actor)
      view |> element("#confirm-delete-label") |> render_click()
      assert has_element?(view, "#labels-empty")
      assert Zaq.Repo.get(Document, document.id)
      assert {:ok, []} = Labels.list(actor)
    end

    test "cancel deletion restores unsaved edit input; stale definition requires reconfirmation",
         %{
           conn: conn,
           actor: actor
         } do
      {:ok, label} = Labels.save_definition(%{name: "Original", resources: ["document"]}, actor)
      {:ok, view, _} = live(conn, ~p"/bo/labels")

      view
      |> element("button[phx-click=edit_label][phx-value-id='#{label.id}']")
      |> render_click()

      view |> form("#label-definition-form", label: %{name: "Unsaved"}) |> render_change()
      view |> element("#delete-label") |> render_click()
      view |> element("button[phx-click=cancel_delete_label]", "Cancel") |> render_click()
      assert has_element?(view, "input[name='label[name]'][value=Unsaved]")
      view |> element("#delete-label") |> render_click()

      assert {:ok, _} =
               Labels.save_definition(
                 %{
                   id: label.id,
                   expected_version: label.lock_version,
                   name: "Renamed",
                   resources: ["document"]
                 },
                 actor
               )

      view |> element("#confirm-delete-label") |> render_click()
      assert has_element?(view, "#delete-label-confirmation", "The label changed")
      assert has_element?(view, "#delete-label-confirmation", "Renamed")
      assert {:ok, [_]} = Labels.list(actor)
      view |> element("#confirm-delete-label") |> render_click()
      assert {:ok, []} = Labels.list(actor)
    end

    test "catalog creates and edits definitions; cancel discards changes", %{
      conn: conn,
      actor: actor
    } do
      {:ok, view, _} = live(conn, ~p"/bo/labels")
      assert has_element?(view, "#labels-empty")
      view |> element("#new-label") |> render_click()
      refute has_element?(view, "#label-automatic-document")
      refute has_element?(view, "#label-automatic-chunk")

      view
      |> form("#label-definition-form",
        label: %{name: "Security", description: "Access", document: "true", chunk: "true"}
      )
      |> render_submit()

      assert has_element?(view, "#labels", "Security")
      {:ok, [label]} = Labels.list(actor)
      assert label.value_type == "boolean"
      assert label.value_config == %{}
      assert label.assignment_type == "manual"
      assert label.threshold == 80

      view
      |> element("button[phx-click=edit_label][phx-value-id='#{label.id}']")
      |> render_click()

      view |> form("#label-definition-form", label: %{name: "Discarded"}) |> render_change()
      view |> element("button[phx-click=close_label_form]", "Cancel") |> render_click()
      assert {:ok, [%{name: "Security"}]} = Labels.list(actor)
    end

    test "definition validation retains the form and input", %{conn: conn, actor: actor} do
      {:ok, _} = Labels.save_definition(%{name: "Security", resources: ["document"]}, actor)
      {:ok, view, _} = live(conn, ~p"/bo/labels")
      view |> element("#new-label") |> render_click()

      view
      |> form("#label-definition-form",
        label: %{name: "security", document: "true", chunk: "false"}
      )
      |> render_submit()

      assert has_element?(view, "#label-definition-form")
      assert render(view) =~ "has already been taken"
    end

    test "automatic scale settings retain invalid input and save through domain validation", %{
      conn: conn,
      actor: actor
    } do
      {:ok, view, _} = live(conn, ~p"/bo/labels")
      view |> element("#new-label") |> render_click()
      assert has_element?(view, "#label-value-type [data-select-value=scale]")
      # SearchableSelect sends its hidden value through the form change event.
      view
      |> form("#label-definition-form")
      |> render_change(%{label: %{value_type: "scale", assignment_type: "automatic"}})

      assert has_element?(view, "#label-definition-form", "remain pending")

      view
      |> form("#label-definition-form",
        label: %{
          name: "Score",
          scale_min: "0",
          scale_max: "10",
          scale_increment: "3",
          threshold: "75"
        }
      )
      |> render_submit()

      assert has_element?(view, "#label-definition-form [role=alert]", "valid scale")
      assert has_element?(view, "input[name='label[scale_increment]'][value='3']")
      assert {:ok, []} = Labels.list(actor)
      view |> form("#label-definition-form", label: %{scale_increment: "2"}) |> render_submit()
      assert {:ok, [label]} = Labels.list(actor)
      assert label.value_config == %{"min" => 0, "max" => 10, "increment" => 2}
      assert label.assignment_type == "automatic"
      assert label.threshold == 75
      assert has_element?(view, "#labels-#{label.id}", "75%")
      assert label.resources == ["document", "chunk"]
    end

    test "option name edits preserve stable IDs and used option removal stays rejected", %{
      conn: conn,
      actor: actor
    } do
      {:ok, view, _} = live(conn, ~p"/bo/labels")
      view |> element("#new-label") |> render_click()
      view |> form("#label-definition-form") |> render_change(%{label: %{value_type: "options"}})
      view |> element("#add-label-option") |> render_click()

      view
      |> form("#label-definition-form",
        label: %{name: "Office", options: %{"0" => %{label: "Paris"}, "1" => %{label: "London"}}}
      )
      |> render_submit()

      assert {:ok, [label]} = Labels.list(actor)
      [paris, london] = label.value_config["options"]
      {:ok, document} = Document.create(%{source: "option-ui"})

      assert {:ok, _} =
               Labels.edit_resource(
                 %{type: "document", id: document.id},
                 [
                   %{
                     label_id: label.id,
                     operation: "add",
                     value: paris["id"],
                     expected_version: 0
                   }
                 ],
                 actor
               )

      view
      |> element("button[phx-click=edit_label][phx-value-id='#{label.id}']")
      |> render_click()

      assert has_element?(view, "input[name='label[options][0][id]'][value='#{paris["id"]}']")

      view
      |> form("#label-definition-form", label: %{options: %{"0" => %{label: "Paris HQ"}}})
      |> render_submit()

      assert {:ok, [renamed]} = Labels.list(actor)
      assert renamed.value_config["options"] == [Map.put(paris, "label", "Paris HQ"), london]
      assert Repo.get_by!(Assignment, document_id: document.id).value == paris["id"]

      view
      |> element("button[phx-click=edit_label][phx-value-id='#{label.id}']")
      |> render_click()

      view
      |> element("button[phx-click=remove_label_option][phx-value-id='#{paris["id"]}']")
      |> render_click()

      view |> form("#label-definition-form") |> render_submit()

      assert has_element?(
               view,
               "#label-definition-form [role=alert]",
               "existing label assignments"
             )

      assert {:ok, [unchanged]} = Labels.list(actor)
      assert unchanged.value_config == renamed.value_config
    end

    test "bulk controls preserve false and zero while updating only confirmed selections", %{
      conn: conn,
      actor: actor
    } do
      for {type, config, before_value, submitted, expected, display} <- [
            {"boolean", %{}, true, "false", false, "False"},
            {"scale", %{"min" => 0, "max" => 10, "increment" => 2}, 2, "0", 0, "0"}
          ] do
        {:ok, label} =
          Labels.save_definition(
            %{
              name: "Bulk #{type}",
              resources: ["document"],
              value_type: type,
              value_config: config
            },
            actor
          )

        {:ok, document} = Document.create(%{source: "bulk-native-#{type}"})

        assert {:ok, _} =
                 Labels.edit_resource(
                   %{type: "document", id: document.id},
                   [
                     %{
                       label_id: label.id,
                       operation: "add",
                       value: before_value,
                       expected_version: 0
                     }
                   ],
                   actor
                 )

        {:ok, view, _} = live(conn, ~p"/bo/labels")
        view |> element("#label-values-#{label.id}") |> render_click()
        view |> element("button[phx-click=show_value_resources]") |> render_click()
        view |> element("#usage-select-all") |> render_click()

        if type == "boolean" do
          assert has_element?(view, "#bulk-label-value [data-select-value=false]")
          view |> form("#label-usage-edit") |> render_submit(%{value: submitted})
        else
          view |> form("#label-usage-edit", value: submitted) |> render_submit()
        end

        assert has_element?(view, "#label-usage-confirm", "“#{display}”")
        assert Repo.get_by!(Assignment, document_id: document.id).value == before_value
        view |> element("#confirm-label-value-update") |> render_click()
        assert Repo.get_by!(Assignment, document_id: document.id).value === expected
      end
    end

    test "pending automatic usage stays distinct until a typed bulk decision is confirmed", %{
      conn: conn,
      actor: actor
    } do
      {:ok, label} =
        Labels.save_definition(
          %{name: "Automatic review", resources: ["document"], assignment_type: "automatic"},
          actor
        )

      {:ok, document} = Document.create(%{source: "pending-bulk-ui"})

      assert {:ok, _} =
               Labels.edit_resource(
                 %{type: "document", id: document.id},
                 [%{label_id: label.id, operation: "add", expected_version: 0}],
                 actor
               )

      {:ok, view, _} = live(conn, ~p"/bo/labels")
      view |> element("#label-values-#{label.id}") |> render_click()

      view
      |> element("button[phx-click=show_value_resources]", "Pending automatic")
      |> render_click()

      view |> element("#usage-select-all") |> render_click()
      assert has_element?(view, "#bulk-label-value [data-select-value=false]")
      view |> form("#label-usage-edit") |> render_submit(%{value: "false"})
      assert Repo.get_by!(Assignment, document_id: document.id).state == :pending
      view |> element("#confirm-label-value-update") |> render_click()

      assert %{state: :assigned, value: false} =
               Repo.get_by!(Assignment, document_id: document.id)
    end

    test "staff can browse but cannot manage definitions", %{conn: conn} do
      user = staff_fixture(%{must_change_password: false})
      conn = init_test_session(conn, %{user_id: user.id})
      {:ok, view, _} = live(conn, ~p"/bo/labels")
      refute has_element?(view, "#new-label")
    end

    test "search spans pages, resets pagination and keeps matching rows editable", %{
      conn: conn,
      actor: actor
    } do
      for n <- 1..51 do
        {:ok, _} =
          Labels.save_definition(%{name: "Category #{n}", resources: ["document"]}, actor)
      end

      {:ok, label} =
        Labels.save_definition(
          %{name: "Security", description: "Authentication and access", resources: ["document"]},
          actor
        )

      {:ok, view, _} = live(conn, ~p"/bo/labels")
      refute has_element?(view, "#labels", "Security")
      view |> element("button[phx-value-direction=next]") |> render_click()
      view |> form("#labels-search-form", query: "AUTHENTICATION") |> render_change()
      assert has_element?(view, "#labels", "Security")
      refute has_element?(view, "#labels", "Category")
      assert has_element?(view, "button[phx-value-direction=previous][disabled]")
      assert has_element?(view, "button[phx-value-direction=next][disabled]")

      view
      |> element("button[phx-click=edit_label][phx-value-id='#{label.id}']")
      |> render_click()

      assert has_element?(
               view,
               "#label-definition-form input[name='label[name]'][value=Security]"
             )

      view |> element("button[phx-click=close_label_form]", "Cancel") |> render_click()
      view |> form("#labels-search-form", query: "seCUR") |> render_change()
      assert has_element?(view, "#labels", "Security")
      view |> form("#labels-search-form", query: "missing") |> render_change()
      assert has_element?(view, "#labels-empty", "No labels match your search.")
      view |> form("#labels-search-form", query: "") |> render_change()
      assert has_element?(view, "#labels", "Category")
      refute has_element?(view, "button[phx-value-direction=next][disabled]")
    end

    test "row selection and typing use cached state without queries", %{conn: conn, actor: actor} do
      {:ok, label} = Labels.save_definition(%{name: "Cached", resources: ["document"]}, actor)
      {:ok, view, _} = live(conn, ~p"/bo/labels")
      handler = "label-query-budget-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:zaq, :repo, :query],
        fn _, _, metadata, _ ->
          send(test_pid, {:label_query, self(), metadata.query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      view
      |> element("button[phx-click=edit_label][phx-value-id='#{label.id}']")
      |> render_click()

      view |> form("#label-definition-form", label: %{name: "Local typing"}) |> render_change()
      live_pid = view.pid

      queries =
        for {:label_query, ^live_pid, query} <- Process.info(self(), :messages) |> elem(1),
            do: query

      assert queries == []
    end
  end

  describe "values and usage" do
    setup %{conn: conn} do
      user = super_admin_fixture(%{must_change_password: false})
      actor = %{user_id: user.id}

      {:ok, label} =
        Labels.save_definition(
          %{
            name: "Location",
            resources: ["document"],
            value_type: "options",
            value_config:
              Zaq.LabelFixtures.option_config(["Paris", "London", "Berlin", "Unspecified"])
          },
          actor
        )

      docs =
        for n <- 1..2,
            do: elem(Document.create(%{source: "manage-ui-#{n}", title: "Document #{n}"}), 1)

      for doc <- docs do
        {:ok, _} =
          Labels.edit_resource(
            %{type: "document", id: doc.id},
            [%{label_id: label.id, expected_version: 0, operation: "add", value: "Paris"}],
            actor
          )
      end

      %{
        conn: init_test_session(conn, %{user_id: user.id}),
        actor: actor,
        label: label,
        docs: docs
      }
    end

    test "addon updates preserve the label catalog and selection", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/bo/labels")
      view |> element("#select-all-labels") |> render_click()
      initial_version = :sys.get_state(view.pid).socket.assigns.features_version

      send(view.pid, :addons_updated)
      render(view)

      assert :sys.get_state(view.pid).socket.assigns.features_version == initial_version + 1
      assert has_element?(view, "#labels-#{ctx.label.id}.zaq-table-row--selected")
      assert has_element?(view, "#label-values-#{ctx.label.id}", "1 / 2")
      assert has_element?(view, "#delete-selected-labels", "Delete (1)")
    end

    test "catalog usage opens matching resources and changes only the selection after confirmation",
         ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/bo/labels")
      assert has_element?(view, "#label-values-#{ctx.label.id}", "1 / 2")
      view |> element("#label-values-#{ctx.label.id}") |> render_click()
      assert has_element?(view, "#label-usage", "Paris")
      view |> element("button[phx-click=show_value_resources]", "Paris") |> render_click()
      doc = hd(ctx.docs)
      view |> element("#usage-select-document-#{doc.id}") |> render_click()
      view |> form("#label-usage-edit") |> render_submit(%{value: "London"})
      assert has_element?(view, "#label-usage-confirm", "1 selected resource")
      assert Repo.get_by!(Assignment, document_id: doc.id).value == "Paris"
      view |> element("#confirm-label-value-update") |> render_click()
      assert Repo.get_by!(Assignment, document_id: doc.id).value == "London"

      assert Repo.get_by!(Assignment, document_id: List.last(ctx.docs).id).value ==
               "Paris"

      assert has_element?(view, "#label-values-#{ctx.label.id}", "2 / 2")
    end

    test "explicit unspecified retains assignments, cancel does not write and usage is discoverable",
         ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/bo/labels")
      view |> element("#label-values-#{ctx.label.id}") |> render_click()
      view |> element("button[phx-click=show_value_resources]", "Paris") |> render_click()
      view |> element("#usage-select-all") |> render_click()
      view |> form("#label-usage-edit") |> render_submit(%{value: "Unspecified"})
      view |> element("#cancel-label-value-update") |> render_click()
      assert Enum.all?(Repo.all(Assignment), &(&1.value == "Paris"))
      view |> form("#label-usage-edit") |> render_submit(%{value: "Unspecified"})
      view |> element("#confirm-label-value-update") |> render_click()

      assert Enum.all?(
               Repo.all(Assignment),
               &(&1.value == "Unspecified" and &1.state == :assigned)
             )

      view |> element("button[phx-click=show_values]") |> render_click()
      assert has_element?(view, "button[phx-click=show_value_resources]", "Unspecified")
      refute has_element?(view, "button[phx-click=show_value_resources]", "Paris")
    end

    test "pagination clears selection and select all only selects the visible page", ctx do
      for n <- 1..51 do
        {:ok, doc} = Document.create(%{source: "usage-page-#{n}"})

        Repo.insert!(%Assignment{
          resource_type: "document",
          resource_id: to_string(doc.id),
          label_id: ctx.label.id,
          state: :assigned,
          origin: :manual,
          value: "Paris"
        })
      end

      {:ok, view, _} = live(ctx.conn, ~p"/bo/labels")
      view |> element("#label-values-#{ctx.label.id}") |> render_click()
      view |> element("button[phx-click=show_value_resources]", "Paris") |> render_click()
      view |> element("#usage-select-all") |> render_click()
      assert has_element?(view, "#review-label-value-update", "(50)")

      view
      |> element("#label-usage button[phx-click=usage_page][phx-value-direction=next]")
      |> render_click()

      assert has_element?(view, "#review-label-value-update[disabled]", "(0)")
      view |> element("#usage-select-all") |> render_click()
      assert has_element?(view, "#review-label-value-update", "(3)")
    end

    test "stale update keeps confirmation visible and reload clears selection", ctx do
      {:ok, view, _} = live(ctx.conn, ~p"/bo/labels")
      view |> element("#label-values-#{ctx.label.id}") |> render_click()
      view |> element("button[phx-click=show_value_resources]", "Paris") |> render_click()
      view |> element("#usage-select-all") |> render_click()
      view |> form("#label-usage-edit") |> render_submit(%{value: "London"})

      {:ok, _} =
        Labels.edit_resource(
          %{type: "document", id: hd(ctx.docs).id},
          [%{label_id: ctx.label.id, expected_version: 1, operation: "add", value: "Berlin"}],
          ctx.actor
        )

      view |> element("#confirm-label-value-update") |> render_click()
      assert has_element?(view, "#label-usage-error", "changed")
      assert has_element?(view, "#label-usage-confirm")
      view |> element("#reload-label-usage") |> render_click()
      refute has_element?(view, "#label-usage-confirm")
      assert has_element?(view, "#review-label-value-update[disabled]")
    end
  end
end
