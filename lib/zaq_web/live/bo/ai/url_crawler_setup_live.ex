defmodule ZaqWeb.Live.BO.AI.UrlCrawlerSetupLive do
  use ZaqWeb, :live_view

  alias ZaqWeb.Live.BO.AI.UrlCrawlerPreview

  @analysis_delay_ms 900

  @impl true
  def mount(params, _session, socket) do
    configuration_id = params["from"]
    draft = UrlCrawlerPreview.draft_for_configuration!(configuration_id)

    {:ok,
     socket
     |> assign(:page_title, "Crawl Setup")
     |> assign(:current_path, "/bo/ingestion")
     |> assign(:draft, draft)
     |> assign(:form, to_form(form_params(draft), as: :crawl))
     |> assign(:analyzing, false)
     |> assign(:preview_open, false)
     |> assign(:preview_data, nil)
     |> assign(:launch_modal_open, false)
     |> assign(:selected_ingestion_strategy, ".md")
     |> assign(:preview_expanded_paths, MapSet.new())
     |> assign(:share_target_options, UrlCrawlerPreview.share_target_options())
     |> assign(:share_targets, [])}
  end

  @impl true
  def handle_event("validate_setup", %{"crawl" => params}, socket) do
    draft = merge_draft(socket.assigns.draft, params)

    {:noreply,
     socket
     |> assign(:draft, draft)
     |> assign(:form, to_form(form_params(draft), as: :crawl))}
  end

  def handle_event("toggle_max_pages", _params, socket) do
    draft = %{socket.assigns.draft | max_pages_enabled: not socket.assigns.draft.max_pages_enabled}

    {:noreply,
     socket
     |> assign(:draft, draft)
     |> assign(:form, to_form(form_params(draft), as: :crawl))}
  end

  def handle_event("add_rule", %{"list" => list_name, "field" => field_name}, socket) do
    draft = add_rule(socket.assigns.draft, list_name, field_name)

    {:noreply,
     socket
     |> assign(:draft, draft)
     |> assign(:form, to_form(form_params(draft), as: :crawl))}
  end

  def handle_event("remove_rule", %{"list" => list_name, "index" => index}, socket) do
    draft = remove_rule(socket.assigns.draft, list_name, String.to_integer(index))

    {:noreply,
     socket
     |> assign(:draft, draft)
     |> assign(:form, to_form(form_params(draft), as: :crawl))}
  end

  def handle_event("analyze_site", %{"crawl" => params}, socket) do
    draft = merge_draft(socket.assigns.draft, params)
    send(self(), {:finish_analysis, draft})

    {:noreply,
     socket
     |> assign(:draft, draft)
     |> assign(:form, to_form(form_params(draft), as: :crawl))
     |> assign(:analyzing, true)
     |> put_flash(:info, "Analysis started: we are discovering the pages that match your crawl configuration.")}
  end

  def handle_event("close_preview", _params, socket) do
    {:noreply, assign(socket, preview_open: false)}
  end

  def handle_event("toggle_preview_branch", %{"path" => path}, socket) do
    expanded_paths =
      if MapSet.member?(socket.assigns.preview_expanded_paths, path) do
        MapSet.delete(socket.assigns.preview_expanded_paths, path)
      else
        MapSet.put(socket.assigns.preview_expanded_paths, path)
      end

    {:noreply, assign(socket, :preview_expanded_paths, expanded_paths)}
  end

  def handle_event("toggle_preview_item", %{"id" => id}, socket) do
    preview_data =
      update_in(socket.assigns.preview_data.tree_items, fn items ->
        Enum.reject(items, &(&1.id == id))
      end)
      |> normalize_preview_data()

    {:noreply, assign(socket, :preview_data, preview_data)}
  end

  def handle_event("open_launch_modal", _params, socket) do
    {:noreply, assign(socket, launch_modal_open: true, preview_open: false, share_targets: [])}
  end

  def handle_event("close_launch_modal", _params, socket) do
    {:noreply, assign(socket, launch_modal_open: false, preview_open: true)}
  end

  def handle_event("set_ingestion_strategy", %{"strategy" => strategy}, socket) do
    {:noreply, assign(socket, :selected_ingestion_strategy, strategy)}
  end

  def handle_event("add_share_target", %{"value" => value}, socket) do
    case UrlCrawlerPreview.parse_share_target(value) do
      nil ->
        {:noreply, socket}

      entry ->
        share_targets =
          if Enum.any?(socket.assigns.share_targets, &(&1.value == entry.value)) do
            socket.assigns.share_targets
          else
            socket.assigns.share_targets ++ [entry]
          end

        {:noreply, assign(socket, :share_targets, share_targets)}
    end
  end

  def handle_event("remove_share_target", %{"value" => value}, socket) do
    {:noreply, assign(socket, :share_targets, Enum.reject(socket.assigns.share_targets, &(&1.value == value)))}
  end

  def handle_event("run_crawl", _params, socket) do
    configuration_id = save_target_configuration_id(socket.assigns.preview_data, socket.assigns.draft)
    run = UrlCrawlerPreview.latest_run!(configuration_id)

    {:noreply,
     socket
     |> assign(:launch_modal_open, false)
     |> put_flash(:info, "Preview only: the crawl would launch now using #{socket.assigns.selected_ingestion_strategy}.")
     |> push_navigate(to: ~p"/bo/ingestion/url_crawler/#{configuration_id}/runs/#{run.id}")}
  end

  @impl true
  def handle_info({:finish_analysis, draft}, socket) do
    Process.send_after(self(), {:open_preview, draft}, @analysis_delay_ms)
    {:noreply, socket}
  end

  def handle_info({:open_preview, draft}, socket) do
    preview_data = preview_for_draft(draft)

    {:noreply,
     socket
     |> assign(:analyzing, false)
     |> assign(:preview_open, true)
     |> assign_preview_state(preview_data)}
  end

  def depth_options, do: Enum.map(1..5, &{"#{&1}", &1})

  def subdomain_policy_options do
    [
      {"Ignore subdomains", "ignore"},
      {"Include selected subdomains", "include_selected"},
      {"Include all subdomains", "include_all"}
    ]
  end

  def tree_path_text(item), do: Enum.join(item.tree_path || [], " / ")
  def preview_tree_rows(preview_data, expanded_paths), do: UrlCrawlerPreview.tree_rows(preview_data.tree_items, expanded_paths)
  def selected_count(preview_data), do: length(preview_data.tree_items)

  def rule_title("include_paths"), do: "Include paths"
  def rule_title("exclude_paths"), do: "Exclude paths"
  def rule_title("include_query_rules"), do: "Include query rules"
  def rule_title("exclude_query_rules"), do: "Exclude query rules"

  def rule_hint("include_paths"), do: "Add one path or pattern at a time, for example /guides/* or /pricing."
  def rule_hint("exclude_paths"), do: "Use excludes to remove noisy or private branches such as /archive/* or /internal/*."
  def rule_hint("include_query_rules"), do: "Use query rules to keep variants such as lang=en when they matter."
  def rule_hint("exclude_query_rules"), do: "Use query rules to block duplicates such as utm_* or preview=true."

  defp merge_draft(draft, params) do
    content_filters = Map.get(params, "content_filters", %{})

    %{
      draft
      | crawl_label: Map.get(params, "crawl_label", draft.crawl_label),
        root_url: Map.get(params, "root_url", draft.root_url),
        depth: to_int(Map.get(params, "depth"), draft.depth),
        subdomain_policy: Map.get(params, "subdomain_policy", draft.subdomain_policy),
        max_pages: to_int(Map.get(params, "max_pages"), draft.max_pages),
        include_path_entry: Map.get(params, "include_path_entry", draft.include_path_entry),
        exclude_path_entry: Map.get(params, "exclude_path_entry", draft.exclude_path_entry),
        include_query_rule_entry: Map.get(params, "include_query_rule_entry", draft.include_query_rule_entry),
        exclude_query_rule_entry: Map.get(params, "exclude_query_rule_entry", draft.exclude_query_rule_entry),
        content_filters: %{
          pdf_files: checkbox_enabled?(content_filters, "pdf_files", draft.content_filters.pdf_files),
          img_files: checkbox_enabled?(content_filters, "img_files", draft.content_filters.img_files),
          md_files: checkbox_enabled?(content_filters, "md_files", draft.content_filters.md_files),
          docs_pages: checkbox_enabled?(content_filters, "docs_pages", draft.content_filters.docs_pages),
          pptx_files: checkbox_enabled?(content_filters, "pptx_files", draft.content_filters.pptx_files),
          excel_files: checkbox_enabled?(content_filters, "excel_files", draft.content_filters.excel_files)
        }
    }
  end

  defp add_rule(draft, list_name, field_name) do
    list_key = String.to_existing_atom(list_name)
    field_key = String.to_existing_atom(field_name)
    value = draft |> Map.fetch!(field_key) |> String.trim()

    if value == "" do
      draft
    else
      existing = Map.fetch!(draft, list_key)

      draft
      |> Map.put(list_key, existing ++ [value])
      |> Map.put(field_key, "")
    end
  end

  defp remove_rule(draft, list_name, index) do
    list_key = String.to_existing_atom(list_name)
    rules = draft |> Map.fetch!(list_key) |> List.delete_at(index)
    Map.put(draft, list_key, rules)
  end

  defp preview_for_draft(draft) do
    preview =
      cond do
        String.contains?(draft.root_url, "invest") ->
          UrlCrawlerPreview.preview!("investor")

        String.contains?(draft.root_url, "docs") ->
          UrlCrawlerPreview.preview!("docs")

        String.contains?(draft.root_url, "support") ->
          UrlCrawlerPreview.preview!("support")

        String.contains?(draft.root_url, "private") ->
          UrlCrawlerPreview.preview!("empty")

        true ->
          UrlCrawlerPreview.preview!("marketing")
      end

    if preview.tree_items == [] do
      %{preview | blocked?: true, block_reason: "No eligible pages were found with the current rules."}
    else
      preview
      |> Map.put(:root_url, draft.root_url)
      |> normalize_preview_data()
    end
  end

  defp normalize_preview_data(preview_data) do
    if preview_data.tree_items == [] do
      %{preview_data | blocked?: true, block_reason: "Select at least one page before launching the crawl."}
    else
      %{preview_data | blocked?: false, block_reason: nil}
    end
  end

  defp save_target_configuration_id(preview_data, draft) do
    preview_id = preview_data && preview_data.id

    case {draft.config_id, preview_id} do
      {config_id, _} when is_binary(config_id) -> config_id
      {_, preview_id} when is_binary(preview_id) -> UrlCrawlerPreview.save_target_configuration_id(preview_id)
      _ -> "cfg-docs"
    end
  end

  defp to_int(nil, fallback), do: fallback
  defp to_int(value, _fallback) when is_integer(value), do: value

  defp to_int(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> fallback
    end
  end

  defp checkbox_enabled?(params, key, _fallback) when is_map_key(params, key), do: true
  defp checkbox_enabled?(_params, _key, _fallback), do: false

  def strategy_options, do: UrlCrawlerPreview.strategy_options()

  defp assign_preview_state(socket, preview_data) do
    socket
    |> assign(:preview_data, preview_data)
    |> assign(:preview_expanded_paths, UrlCrawlerPreview.default_expanded_paths(preview_data.tree_items))
  end

  defp form_params(value) when is_map(value) do
    Map.new(value, fn {key, val} -> {to_string(key), form_params(val)} end)
  end

  defp form_params(value) when is_list(value), do: Enum.map(value, &form_params/1)
  defp form_params(value), do: value
end
