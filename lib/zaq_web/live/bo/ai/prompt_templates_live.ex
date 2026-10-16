defmodule ZaqWeb.Live.BO.AI.PromptTemplatesLive do
  use ZaqWeb, :live_view

  import ZaqWeb.Components.MarkdownEditor

  alias Zaq.Agent.{Events, PromptTemplate}
  alias Zaq.NodeRouter
  alias ZaqWeb.ChangesetErrors
  alias ZaqWeb.Live.BO.AI.BOActor

  def mount(_params, _session, socket) do
    templates = template_call(socket, :list, [])
    first_tab = if templates == [], do: :new, else: hd(templates).id

    {:ok,
     assign(socket,
       current_path: "/bo/prompt-templates",
       templates: templates,
       active_tab: first_tab,
       form: build_form(first_tab, templates),
       body_preview: false,
       delete_confirm: nil,
       delete_confirm_name: nil
     )}
  end

  def handle_event("switch_tab", %{"id" => id}, socket) do
    tab = if id == "new", do: :new, else: String.to_integer(id)

    {:noreply,
     assign(socket,
       active_tab: tab,
       form: build_form(tab, socket.assigns.templates),
       body_preview: false,
       delete_confirm: nil,
       delete_confirm_name: nil
     )}
  end

  def handle_event("validate", %{"prompt_template" => params}, socket) do
    changeset = PromptTemplate.changeset(current_base(socket), params)
    {:noreply, assign(socket, form: to_form(changeset, as: :prompt_template))}
  end

  def handle_event("toggle_body_preview", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, body_preview: mode == "preview")}
  end

  def handle_event("save", %{"prompt_template" => params}, socket) do
    id = String.to_integer(params["id"])
    template = Enum.find(socket.assigns.templates, &(&1.id == id))

    case template_call(socket, :update, [template, params]) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> apply_update(updated)
         |> assign(form: to_form(PromptTemplate.changeset(updated, %{}), as: :prompt_template))
         |> put_flash(:info, "\"#{updated.name}\" saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset, as: :prompt_template))
         |> put_flash(:error, "Save failed: #{format_errors(changeset)}")}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, "Save failed. Template no longer exists or is unavailable.")}
    end
  end

  def handle_event("restore_default", %{"id" => id}, socket) do
    case template_call(socket, :restore_default, [String.to_integer(id)]) do
      {:ok, updated} ->
        # Restore only the body. Keep unrelated unsaved metadata in the form,
        # without persisting it as a side effect of this action.
        draft =
          socket.assigns.form.source
          |> Ecto.Changeset.apply_changes()
          |> Map.take([:name, :description])

        form = updated |> PromptTemplate.changeset(draft) |> to_form(as: :prompt_template)

        {:noreply,
         socket
         |> apply_update(updated)
         |> assign(form: form)
         |> put_flash(:info, "Default restored. Future default updates will apply automatically.")}

      {:error, :no_default} ->
        {:noreply, put_flash(socket, :error, "No default is available for this template.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Template no longer exists.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Restore failed. Your draft has been preserved.")}
    end
  end

  def handle_event("create", %{"prompt_template" => params}, socket) do
    case template_call(socket, :create, [params]) do
      {:ok, created} ->
        templates = template_call(socket, :list, [])

        {:noreply,
         socket
         |> assign(
           templates: templates,
           active_tab: created.id,
           form: build_form(created.id, templates),
           body_preview: false
         )
         |> put_flash(:info, "\"#{created.name}\" created.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset, as: :prompt_template))
         |> put_flash(:error, "Create failed: #{format_errors(changeset)}")}
    end
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    delete_id = String.to_integer(id)
    template = Enum.find(socket.assigns.templates, &(&1.id == delete_id))

    {:noreply,
     assign(socket,
       delete_confirm: delete_id,
       delete_confirm_name: if(template, do: template.name, else: nil)
     )}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, delete_confirm: nil, delete_confirm_name: nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    id = String.to_integer(id)
    template = Enum.find(socket.assigns.templates, &(&1.id == id))

    case template_call(socket, :delete, [template]) do
      {:ok, _} ->
        templates = Enum.reject(socket.assigns.templates, &(&1.id == id))
        next_tab = if templates == [], do: :new, else: hd(templates).id

        {:noreply,
         socket
         |> assign(
           templates: templates,
           active_tab: next_tab,
           delete_confirm: nil,
           delete_confirm_name: nil
         )
         |> put_flash(:info, "\"#{template.name}\" deleted.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Delete failed.")}
    end
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    id = String.to_integer(id)
    template = Enum.find(socket.assigns.templates, &(&1.id == id))

    case template_call(socket, :update, [template, %{active: !template.active}]) do
      {:ok, updated} -> {:noreply, apply_update(socket, updated)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to toggle active state.")}
    end
  end

  # --- Private ---

  defp template_call(socket, function, args) do
    %{module: PromptTemplate, function: function, args: args}
    |> Events.build_invoke_event(:invoke, actor: BOActor.build(socket.assigns.current_user))
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end

  defp apply_update(socket, updated) do
    templates =
      Enum.map(socket.assigns.templates, fn t ->
        if t.id == updated.id, do: updated, else: t
      end)

    assign(socket, templates: templates)
  end

  defp build_form(tab, templates) do
    tab
    |> base_template(templates)
    |> PromptTemplate.changeset(%{})
    |> to_form(as: :prompt_template)
  end

  defp current_base(socket) do
    base_template(socket.assigns.active_tab, socket.assigns.templates)
  end

  defp base_template(:new, _templates), do: %PromptTemplate{}

  defp base_template(id, templates) do
    Enum.find(templates, &(&1.id == id)) || %PromptTemplate{}
  end

  defp format_errors(changeset) do
    ChangesetErrors.format(changeset, separator: "; ")
  end
end
