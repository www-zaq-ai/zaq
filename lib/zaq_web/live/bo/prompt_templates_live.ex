# lib/zaq_web/live/bo/prompt_templates_live.ex

defmodule ZaqWeb.Live.BO.PromptTemplatesLive do
  use ZaqWeb, :live_view

  alias Zaq.Agent.PromptTemplate

  def mount(_params, _session, socket) do
    templates = PromptTemplate.list()
    first_tab = if templates == [], do: :new, else: hd(templates).id

    {:ok,
     assign(socket,
       current_path: "/bo/prompt-templates",
       templates: templates,
       active_tab: first_tab,
       new_form: new_changeset(),
       delete_confirm: nil
     )}
  end

  def handle_event("switch_tab", %{"id" => id}, socket) do
    tab = if id == "new", do: :new, else: String.to_integer(id)
    {:noreply, assign(socket, active_tab: tab, delete_confirm: nil)}
  end

  def handle_event("save", %{"prompt_template" => params}, socket) do
    id = String.to_integer(params["id"])
    template = Enum.find(socket.assigns.templates, &(&1.id == id))

    case PromptTemplate.update(template, params) do
      {:ok, updated} ->
        {:noreply,
         socket |> apply_update(updated) |> put_flash(:info, "\"#{updated.name}\" saved.")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{format_errors(changeset)}")}
    end
  end

  def handle_event("create", %{"prompt_template" => params}, socket) do
    case PromptTemplate.create(params) do
      {:ok, created} ->
        templates = PromptTemplate.list()

        {:noreply,
         socket
         |> assign(templates: templates, active_tab: created.id, new_form: new_changeset())
         |> put_flash(:info, "\"#{created.name}\" created.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(new_form: changeset)
         |> put_flash(:error, "Create failed: #{format_errors(changeset)}")}
    end
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, delete_confirm: String.to_integer(id))}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, delete_confirm: nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    id = String.to_integer(id)
    template = Enum.find(socket.assigns.templates, &(&1.id == id))

    case Zaq.Repo.delete(template) do
      {:ok, _} ->
        templates = Enum.reject(socket.assigns.templates, &(&1.id == id))
        next_tab = if templates == [], do: :new, else: hd(templates).id

        {:noreply,
         socket
         |> assign(templates: templates, active_tab: next_tab, delete_confirm: nil)
         |> put_flash(:info, "\"#{template.name}\" deleted.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Delete failed.")}
    end
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    id = String.to_integer(id)
    template = Enum.find(socket.assigns.templates, &(&1.id == id))

    case PromptTemplate.update(template, %{active: !template.active}) do
      {:ok, updated} -> {:noreply, apply_update(socket, updated)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to toggle active state.")}
    end
  end

  # --- Private ---

  defp apply_update(socket, updated) do
    templates =
      Enum.map(socket.assigns.templates, fn t ->
        if t.id == updated.id, do: updated, else: t
      end)

    assign(socket, templates: templates)
  end

  defp new_changeset do
    PromptTemplate.changeset(%PromptTemplate{}, %{})
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end
end
