defmodule ZaqWeb.Live.BO.AI.UrlCrawlerPreview do
  @moduledoc false

  @statuses [
    "draft",
    "analyzing",
    "ready_for_approval",
    "running",
    "done",
    "partial_success",
    "failed",
    "cancelled"
  ]

  @list_filters ["all" | @statuses]

  def list_filters, do: @list_filters
  def workflow_statuses, do: @statuses

  def list_rows(filter \\ "all", query \\ "") do
    configurations()
    |> Enum.filter(fn config -> filter_match?(config, filter) end)
    |> Enum.filter(fn config ->
      query = String.downcase(String.trim(query || ""))

      query == "" or
        String.contains?(String.downcase(config.crawl_label), query) or
        String.contains?(String.downcase(config.root_url), query) or
        String.contains?(String.downcase(config.id), query)
    end)
  end

  def counters(rows \\ nil) do
    rows = rows || configurations()

    %{
      total: length(rows),
      active: Enum.count(rows, &(&1.latest_status in ["analyzing", "ready_for_approval", "running"])),
      attention: Enum.count(rows, &(&1.latest_status in ["partial_success", "failed"])),
      ingested: Enum.reduce(rows, 0, &(&1.last_ingested_items + &2))
    }
  end

  defp filter_match?(_config, "all"), do: true
  defp filter_match?(config, "active"), do: config.latest_status in ["analyzing", "ready_for_approval", "running"]
  defp filter_match?(config, "attention"), do: config.latest_status in ["partial_success", "failed"]
  defp filter_match?(config, "ingested"), do: config.last_ingested_items > 0
  defp filter_match?(config, filter), do: config.latest_status == filter

  def configurations do
    [
      %{
        id: "cfg-marketing",
        crawl_label: "Marketing site weekly refresh",
        root_url: "https://www.zaq.ai",
        scope_summary: "Depth 2 · No page limit · HTML + docs + marketing",
        latest_run_id: "run-2026-041",
        latest_run_at: "2026-04-22 10:17 UTC",
        latest_status: "running",
        runs_count: 3,
        last_ingested_items: 24,
        volume_namespace: "web/crawled/marketing"
      },
      %{
        id: "cfg-docs",
        crawl_label: "Docs IA refresh",
        root_url: "https://docs.zaq.ai",
        scope_summary: "Depth 4 · Limit 200 pages · HTML + docs",
        latest_run_id: "run-2026-036",
        latest_run_at: "2026-04-21 15:50 UTC",
        latest_status: "done",
        runs_count: 4,
        last_ingested_items: 91,
        volume_namespace: "web/crawled/docs"
      },
      %{
        id: "cfg-investor",
        crawl_label: "Investor perimeter review",
        root_url: "https://investors.zaq.ai",
        scope_summary: "Depth 2 · Limit 40 pages · HTML + PDF + public files",
        latest_run_id: "run-2026-029",
        latest_run_at: "2026-04-20 12:57 UTC",
        latest_status: "partial_success",
        runs_count: 2,
        last_ingested_items: 6,
        volume_namespace: "web/crawled/investor"
      },
      %{
        id: "cfg-support",
        crawl_label: "Support microsite analysis",
        root_url: "https://support.zaq.ai",
        scope_summary: "Depth 2 · No page limit · HTML + docs + public files",
        latest_run_id: "run-2026-046",
        latest_run_at: "2026-04-23 11:04 UTC",
        latest_status: "analyzing",
        runs_count: 1,
        last_ingested_items: 0,
        volume_namespace: "web/crawled/support"
      }
    ]
  end

  def configuration!(id) do
    Enum.find(configurations(), &(&1.id == id)) || hd(configurations())
  end

  def runs_for_configuration!(configuration_id) do
    Map.get(runs_by_configuration(), configuration_id, [])
  end

  def latest_run!(configuration_id) do
    runs_for_configuration!(configuration_id) |> List.first()
  end

  def run!(configuration_id, run_id) do
    Enum.find(runs_for_configuration!(configuration_id), &(&1.id == run_id)) || latest_run!(configuration_id)
  end

  def run!(run_id) do
    runs_by_configuration()
    |> Map.values()
    |> List.flatten()
    |> Enum.find(&(&1.id == run_id))
  end

  def draft!(id) do
    Map.get(drafts(), id) || Map.fetch!(drafts(), "new")
  end

  def draft_for_configuration!(configuration_id) do
    Map.get(drafts(), configuration_id) || Map.fetch!(drafts(), "new")
  end

  def preview!(id) do
    Map.get(previews(), id) || Map.fetch!(previews(), "new")
  end

  def preview_for_configuration!(configuration_id) do
    case configuration_id do
      "cfg-marketing" -> preview!("marketing")
      "cfg-docs" -> preview!("docs")
      "cfg-investor" -> preview!("investor")
      "cfg-support" -> preview!("support")
      _ -> preview!("new")
    end
  end

  def save_target_configuration_id("marketing"), do: "cfg-marketing"
  def save_target_configuration_id("docs"), do: "cfg-docs"
  def save_target_configuration_id("investor"), do: "cfg-investor"
  def save_target_configuration_id("support"), do: "cfg-support"
  def save_target_configuration_id(_), do: "cfg-docs"

  def strategy_options do
    [
      {".md", ".md"},
      {"RAG", "rag"}
    ]
  end

  def share_target_options do
    [
      {"team: Product", "team:product"},
      {"team: Sales", "team:sales"},
      {"team: Support", "team:support"},
      {"Alice Martin (alice@zaq.ai)", "person:alice"},
      {"Nora Smith (nora@zaq.ai)", "person:nora"}
    ]
  end

  def parse_share_target("team:" <> id) do
    label = Enum.find_value(share_target_options(), fn {label, value} -> if value == "team:" <> id, do: label end)
    %{value: "team:" <> id, label: label || id, type: :team}
  end

  def parse_share_target("person:" <> id) do
    label = Enum.find_value(share_target_options(), fn {label, value} -> if value == "person:" <> id, do: label end)
    %{value: "person:" <> id, label: label || id, type: :person}
  end

  def parse_share_target(_), do: nil

  def default_expanded_paths(items) do
    items
    |> Enum.flat_map(fn item ->
      item.tree_path
      |> Enum.drop(-1)
      |> Enum.scan([], fn segment, acc -> acc ++ [segment] end)
      |> Enum.map(&path_key/1)
    end)
    |> MapSet.new()
  end

  def tree_rows(items, expanded_paths) do
    items
    |> build_tree()
    |> Enum.flat_map(&flatten_node(&1, expanded_paths))
  end

  def crawl_output_file_details(relative_path) do
    runs_by_configuration()
    |> Map.values()
    |> List.flatten()
    |> Enum.find_value(fn run ->
      Enum.find_value(run.created_knowledge_items, fn item ->
        if item.path == relative_path do
          %{
            file_title: item.title,
            source_url: item.source_url,
            output_path: item.path,
            run_id: run.id,
            run_status: run.status,
            run_launched_at: run.launched_at,
            run_last_update: run.last_update,
            configuration_id: run.configuration_id,
            configuration_label: run.crawl_label,
            ingestion_strategy: run.ingestion_strategy
          }
        end
      end)
    end)
  end

  def status_label("ready_for_approval"), do: "Ready for approval"
  def status_label("partial_success"), do: "Partial success"
  def status_label(status), do: status |> String.replace("_", " ") |> String.capitalize()

  def status_classes("draft"), do: "bg-slate-100 text-slate-700"
  def status_classes("analyzing"), do: "bg-sky-100 text-sky-700"
  def status_classes("ready_for_approval"), do: "bg-indigo-100 text-indigo-700"
  def status_classes("running"), do: "bg-violet-100 text-violet-700"
  def status_classes("done"), do: "bg-emerald-100 text-emerald-700"
  def status_classes("partial_success"), do: "bg-amber-100 text-amber-700"
  def status_classes("failed"), do: "bg-rose-100 text-rose-700"
  def status_classes("cancelled"), do: "bg-zinc-100 text-zinc-600"
  def status_classes("included"), do: "bg-emerald-100 text-emerald-700"
  def status_classes("excluded"), do: "bg-rose-100 text-rose-700"
  def status_classes("selected"), do: "bg-indigo-100 text-indigo-700"
  def status_classes("not_selected"), do: "bg-zinc-100 text-zinc-600"
  def status_classes("ingested"), do: "bg-emerald-100 text-emerald-700"
  def status_classes("failed_item"), do: "bg-rose-100 text-rose-700"
  def status_classes(_), do: "bg-black/5 text-black/40"

  def frequency_label("one_time"), do: "One-time run"
  def frequency_label("weekly"), do: "Weekly"
  def frequency_label("monthly"), do: "Monthly"
  def frequency_label(other), do: other

  defp build_tree(items) do
    items
    |> Enum.reduce(%{}, fn item, acc -> insert_tree_node(acc, item.tree_path, item) end)
    |> Map.values()
    |> Enum.sort_by(&{&1.kind != :branch, &1.label})
  end

  defp insert_tree_node(tree, [label], item) do
    Map.put(tree, path_key(item.tree_path), %{
      kind: :leaf,
      key: path_key(item.tree_path),
      label: label,
      depth: length(item.tree_path) - 1,
      item: item
    })
  end

  defp insert_tree_node(tree, [label | rest], item) do
    key =
      item.tree_path
      |> Enum.take(length(item.tree_path) - length(rest))
      |> path_key()

    node = Map.get(tree, key, %{kind: :branch, key: key, label: label, depth: path_depth(key), children: %{}})
    children = insert_tree_node(node.children, rest, item)
    Map.put(tree, key, %{node | children: children})
  end

  defp flatten_tree(nodes, expanded_paths) do
    nodes
    |> Enum.flat_map(fn node -> flatten_node(node, expanded_paths) end)
  end

  defp flatten_node(%{kind: :leaf, item: item, depth: depth, key: key}, _expanded_paths) do
    [%{kind: :leaf, key: key, depth: depth, item: item}]
  end

  defp flatten_node(%{kind: :branch, key: key, label: label, depth: depth, children: children}, expanded_paths) do
    expanded? = MapSet.member?(expanded_paths, key)
    branch = %{kind: :branch, key: key, label: label, depth: depth, expanded?: expanded?, children_count: map_size(children)}

    if expanded? do
      [branch | flatten_tree(children |> Map.values() |> Enum.sort_by(&{&1.kind != :branch, &1.label}), expanded_paths)]
    else
      [branch]
    end
  end

  defp path_depth(""), do: 0
  defp path_depth(key), do: length(String.split(key, "/")) - 1
  defp path_key(parts), do: Enum.join(parts, "/")

  defp drafts do
    %{
      "new" => %{
        id: "new",
        config_id: nil,
        crawl_label: "New crawl configuration",
        root_url: "https://docs.zaq.ai",
        depth: 3,
        subdomain_policy: "ignore",
        max_pages_enabled: true,
        max_pages: 120,
        include_paths: ["/guides/*", "/api/*"],
        exclude_paths: ["/changelog/*"],
        include_query_rules: ["lang=en"],
        exclude_query_rules: ["preview=true"],
        include_path_entry: "",
        exclude_path_entry: "",
        include_query_rule_entry: "",
        exclude_query_rule_entry: "",
        content_filters: content_filters(true, true, true, true, true, true),
        preview_id: "new"
      },
      "cfg-marketing" => %{
        id: "cfg-marketing",
        config_id: "cfg-marketing",
        crawl_label: "Marketing site weekly refresh",
        root_url: "https://www.zaq.ai",
        depth: 2,
        subdomain_policy: "ignore",
        max_pages_enabled: false,
        max_pages: 60,
        include_paths: ["/product/*", "/pricing", "/security"],
        exclude_paths: ["/legal/*"],
        include_query_rules: [],
        exclude_query_rules: ["utm_*"],
        include_path_entry: "",
        exclude_path_entry: "",
        include_query_rule_entry: "",
        exclude_query_rule_entry: "",
        content_filters: content_filters(true, false, false, true, false, false),
        preview_id: "marketing"
      },
      "cfg-docs" => %{
        id: "cfg-docs",
        config_id: "cfg-docs",
        crawl_label: "Docs IA refresh",
        root_url: "https://docs.zaq.ai",
        depth: 4,
        subdomain_policy: "ignore",
        max_pages_enabled: true,
        max_pages: 200,
        include_paths: ["/guides/*", "/api/*", "/architecture"],
        exclude_paths: ["/archive/*"],
        include_query_rules: [],
        exclude_query_rules: ["utm_*"],
        include_path_entry: "",
        exclude_path_entry: "",
        include_query_rule_entry: "",
        exclude_query_rule_entry: "",
        content_filters: content_filters(true, false, true, true, false, false),
        preview_id: "docs"
      },
      "cfg-investor" => %{
        id: "cfg-investor",
        config_id: "cfg-investor",
        crawl_label: "Investor perimeter review",
        root_url: "https://investors.zaq.ai",
        depth: 2,
        subdomain_policy: "ignore",
        max_pages_enabled: true,
        max_pages: 40,
        include_paths: ["/overview", "/governance", "/results/*"],
        exclude_paths: ["/login", "/private/*"],
        include_query_rules: [],
        exclude_query_rules: ["download_token=*"],
        include_path_entry: "",
        exclude_path_entry: "",
        include_query_rule_entry: "",
        exclude_query_rule_entry: "",
        content_filters: content_filters(true, false, false, false, false, false),
        preview_id: "investor"
      },
      "cfg-support" => %{
        id: "cfg-support",
        config_id: "cfg-support",
        crawl_label: "Support microsite analysis",
        root_url: "https://support.zaq.ai",
        depth: 2,
        subdomain_policy: "ignore",
        max_pages_enabled: false,
        max_pages: 120,
        include_paths: ["/articles/*", "/faq/*"],
        exclude_paths: ["/internal/*"],
        include_query_rules: [],
        exclude_query_rules: [],
        include_path_entry: "",
        exclude_path_entry: "",
        include_query_rule_entry: "",
        exclude_query_rule_entry: "",
        content_filters: content_filters(true, true, false, true, false, true),
        preview_id: "support"
      }
    }
  end

  defp previews do
    %{
      "new" => %{id: "new", config_id: nil, root_url: "https://docs.zaq.ai", blocked?: false, block_reason: nil, tree_items: selected_tree(:new)},
      "marketing" => %{id: "marketing", config_id: "cfg-marketing", root_url: "https://www.zaq.ai", blocked?: false, block_reason: nil, tree_items: selected_tree(:marketing)},
      "docs" => %{id: "docs", config_id: "cfg-docs", root_url: "https://docs.zaq.ai", blocked?: false, block_reason: nil, tree_items: selected_tree(:docs)},
      "investor" => %{id: "investor", config_id: "cfg-investor", root_url: "https://investors.zaq.ai", blocked?: false, block_reason: nil, tree_items: selected_tree(:investor)},
      "support" => %{id: "support", config_id: "cfg-support", root_url: "https://support.zaq.ai", blocked?: false, block_reason: nil, tree_items: selected_tree(:support)},
      "empty" => %{id: "empty", config_id: nil, root_url: "https://partners.zaq.ai/private", blocked?: true, block_reason: "No eligible pages were found with the current rules.", tree_items: []}
    }
  end

  defp runs_by_configuration do
    %{
      "cfg-marketing" => [
        %{
          id: "run-2026-041",
          configuration_id: "cfg-marketing",
          crawl_label: "Marketing site weekly refresh",
          root_url: "https://www.zaq.ai",
          launched_at: "2026-04-22 10:17 UTC",
          last_update: "2026-04-22 10:42 UTC",
          status: "running",
          progress: 68,
          detected_items: 44,
          detected_files: 6,
          selected_pages: 44,
          crawled_pages: 38,
          ingested_items: 24,
          files_written: 24,
          failed_items_count: 0,
          ingestion_strategy: "RAG",
          source_type: "website",
          original_source_url: "https://www.zaq.ai",
          output_namespace: "web/crawled/marketing",
          settings_snapshot: settings_snapshot(:marketing),
          approved_page_list: selected_tree(:marketing),
          created_knowledge_items: knowledge_items(:marketing),
          failed_items: [],
          timeline: [
            %{label: "Run started", at: "2026-04-22 10:17 UTC", detail: "Crawler job started from configuration cfg-marketing."},
            %{label: "Discovery", at: "2026-04-22 10:20 UTC", detail: "44 pages discovered under the configured perimeter."},
            %{label: "Ingestion", at: "2026-04-22 10:42 UTC", detail: "24 files already replaced the previous crawl output in the URL Crawling volume."}
          ]
        },
        %{
          id: "run-2026-032",
          configuration_id: "cfg-marketing",
          crawl_label: "Marketing site weekly refresh",
          root_url: "https://www.zaq.ai",
          launched_at: "2026-04-15 09:05 UTC",
          last_update: "2026-04-15 09:18 UTC",
          status: "done",
          progress: 100,
          detected_items: 41,
          detected_files: 5,
          selected_pages: 41,
          crawled_pages: 41,
          ingested_items: 27,
          files_written: 27,
          failed_items_count: 0,
          ingestion_strategy: ".md",
          source_type: "website",
          original_source_url: "https://www.zaq.ai",
          output_namespace: "web/crawled/marketing",
          settings_snapshot: settings_snapshot(:marketing),
          approved_page_list: selected_tree(:marketing),
          created_knowledge_items: knowledge_items(:marketing),
          failed_items: [],
          timeline: [
            %{label: "Run completed", at: "2026-04-15 09:18 UTC", detail: "All selected marketing pages were refreshed."}
          ]
        }
      ],
      "cfg-docs" => [
        %{
          id: "run-2026-036",
          configuration_id: "cfg-docs",
          crawl_label: "Docs IA refresh",
          root_url: "https://docs.zaq.ai",
          launched_at: "2026-04-21 15:50 UTC",
          last_update: "2026-04-21 16:14 UTC",
          status: "done",
          progress: 100,
          detected_items: 126,
          detected_files: 9,
          selected_pages: 126,
          crawled_pages: 126,
          ingested_items: 91,
          files_written: 91,
          failed_items_count: 0,
          ingestion_strategy: "RAG",
          source_type: "documentation",
          original_source_url: "https://docs.zaq.ai",
          output_namespace: "web/crawled/docs",
          settings_snapshot: settings_snapshot(:docs),
          approved_page_list: selected_tree(:docs),
          created_knowledge_items: knowledge_items(:docs),
          failed_items: [],
          timeline: [
            %{label: "Run completed", at: "2026-04-21 16:03 UTC", detail: "All selected docs pages were crawled."},
            %{label: "Knowledge updated", at: "2026-04-21 16:14 UTC", detail: "Existing files under web/crawled/docs were refreshed in place."}
          ]
        },
        %{
          id: "run-2026-021",
          configuration_id: "cfg-docs",
          crawl_label: "Docs IA refresh",
          root_url: "https://docs.zaq.ai",
          launched_at: "2026-04-12 11:12 UTC",
          last_update: "2026-04-12 11:31 UTC",
          status: "done",
          progress: 100,
          detected_items: 118,
          detected_files: 8,
          selected_pages: 118,
          crawled_pages: 118,
          ingested_items: 85,
          files_written: 85,
          failed_items_count: 0,
          ingestion_strategy: "RAG",
          source_type: "documentation",
          original_source_url: "https://docs.zaq.ai",
          output_namespace: "web/crawled/docs",
          settings_snapshot: settings_snapshot(:docs),
          approved_page_list: selected_tree(:docs),
          created_knowledge_items: knowledge_items(:docs),
          failed_items: [],
          timeline: [
            %{label: "Run completed", at: "2026-04-12 11:31 UTC", detail: "Previous docs snapshot saved into history while filesystem output was replaced."}
          ]
        }
      ],
      "cfg-investor" => [
        %{
          id: "run-2026-029",
          configuration_id: "cfg-investor",
          crawl_label: "Investor perimeter review",
          root_url: "https://investors.zaq.ai",
          launched_at: "2026-04-20 12:57 UTC",
          last_update: "2026-04-20 13:06 UTC",
          status: "partial_success",
          progress: 100,
          detected_items: 14,
          detected_files: 3,
          selected_pages: 12,
          crawled_pages: 12,
          ingested_items: 6,
          files_written: 6,
          failed_items_count: 2,
          ingestion_strategy: ".md",
          source_type: "website",
          original_source_url: "https://investors.zaq.ai",
          output_namespace: "web/crawled/investor",
          settings_snapshot: settings_snapshot(:investor),
          approved_page_list: selected_tree(:investor),
          created_knowledge_items: knowledge_items(:investor),
          failed_items: [
            %{title: "Q1 2026 results", url: "https://investors.zaq.ai/results/q1-2026", type: "html", reason: "403 blocked by upstream ACL", partially_ingested: false},
            %{title: "Investor packet PDF", url: "https://investors.zaq.ai/files/investor-packet.pdf", type: "pdf", reason: "PDF normalization failed after download", partially_ingested: true}
          ],
          timeline: [
            %{label: "Run completed with errors", at: "2026-04-20 13:04 UTC", detail: "Two selected items failed during crawl and normalization."}
          ]
        }
      ],
      "cfg-support" => [
        %{
          id: "run-2026-046",
          configuration_id: "cfg-support",
          crawl_label: "Support microsite analysis",
          root_url: "https://support.zaq.ai",
          launched_at: "2026-04-23 11:04 UTC",
          last_update: "2026-04-23 11:05 UTC",
          status: "analyzing",
          progress: 24,
          detected_items: 0,
          detected_files: 0,
          selected_pages: 0,
          crawled_pages: 0,
          ingested_items: 0,
          files_written: 0,
          failed_items_count: 0,
          ingestion_strategy: "RAG",
          source_type: "website",
          original_source_url: "https://support.zaq.ai",
          output_namespace: "web/crawled/support",
          settings_snapshot: settings_snapshot(:support),
          approved_page_list: [],
          created_knowledge_items: [],
          failed_items: [],
          timeline: [
            %{label: "Analyzing", at: "2026-04-23 11:05 UTC", detail: "The run is computing the perimeter before content extraction starts."}
          ]
        }
      ]
    }
  end

  defp content_filters(pdf_files, img_files, md_files, docs_pages, pptx_files, excel_files) do
    %{
      pdf_files: pdf_files,
      img_files: img_files,
      md_files: md_files,
      docs_pages: docs_pages,
      pptx_files: pptx_files,
      excel_files: excel_files
    }
  end

  defp settings_snapshot(kind) do
    case kind do
      :marketing ->
        %{
          depth: 2,
          subdomains: "Ignore subdomains",
          max_pages: "No limit",
          include_paths: ["/product/*", "/pricing", "/security"],
          exclude_paths: ["/legal/*"],
          query_rules: ["exclude utm_*"],
          content: ["PDF", ".md", "docs"]
        }

      :docs ->
        %{
          depth: 4,
          subdomains: "Ignore subdomains",
          max_pages: "Limit 200 pages",
          include_paths: ["/guides/*", "/api/*", "/architecture"],
          exclude_paths: ["/archive/*"],
          query_rules: ["exclude utm_*"],
          content: ["PDF", ".md", "docs"]
        }

      :investor ->
        %{
          depth: 2,
          subdomains: "Ignore subdomains",
          max_pages: "Limit 40 pages",
          include_paths: ["/overview", "/governance", "/results/*"],
          exclude_paths: ["/private/*", "/login"],
          query_rules: ["exclude download_token=*"],
          content: ["PDF"]
        }

      :support ->
        %{
          depth: 2,
          subdomains: "Ignore subdomains",
          max_pages: "No limit",
          include_paths: ["/articles/*", "/faq/*"],
          exclude_paths: ["/internal/*"],
          query_rules: [],
          content: ["PDF", "Img", "docs", "excel"]
        }
    end
  end

  defp selected_tree(kind) do
    case kind do
      :new ->
        [
          %{id: "docs-getting-started", title: "Getting started", url: "https://docs.zaq.ai/guides/getting-started", type: "html", depth_level: 2, tree_path: ["Docs", "Guides", "Getting started"], parent_title: "Guides", metadata: ["selected", "included", "group: guides", "parent: Guides"]},
          %{id: "docs-auth-api", title: "Auth API", url: "https://docs.zaq.ai/api/auth", type: "html", depth_level: 2, tree_path: ["Docs", "API", "Auth API"], parent_title: "API", metadata: ["selected", "included", "group: api", "parent: API"]},
          %{id: "docs-architecture-pdf", title: "Architecture PDF", url: "https://docs.zaq.ai/files/architecture.pdf", type: "pdf", depth_level: 2, tree_path: ["Files", "Architecture PDF"], parent_title: "Files", metadata: ["selected", "included", "format: pdf", "parent: Files"]}
        ]

      :marketing ->
        [
          %{id: "marketing-homepage", title: "Homepage", url: "https://www.zaq.ai/", type: "html", depth_level: 1, tree_path: ["Product", "Homepage"], parent_title: "Product", metadata: ["selected", "included", "group: product", "parent: Product"]},
          %{id: "marketing-kb", title: "Knowledge Base", url: "https://www.zaq.ai/product/knowledge-base", type: "html", depth_level: 2, tree_path: ["Product", "Features", "Knowledge Base"], parent_title: "Features", metadata: ["selected", "included", "group: features", "parent: Features"]},
          %{id: "marketing-pricing", title: "Pricing", url: "https://www.zaq.ai/pricing", type: "html", depth_level: 1, tree_path: ["Commercial", "Pricing"], parent_title: "Commercial", metadata: ["selected", "included", "group: commercial", "parent: Commercial"]}
        ]

      :docs ->
        [
          %{id: "docs-guides-start", title: "Getting started", url: "https://docs.zaq.ai/guides/getting-started", type: "html", depth_level: 2, tree_path: ["Guides", "Getting started"], parent_title: "Guides", metadata: ["selected", "included", "group: guides", "parent: Guides"]},
          %{id: "docs-guides-arch", title: "Architecture", url: "https://docs.zaq.ai/architecture", type: "html", depth_level: 1, tree_path: ["Guides", "Architecture"], parent_title: "Guides", metadata: ["selected", "included", "group: guides", "parent: Guides"]},
          %{id: "docs-api-auth", title: "Authentication", url: "https://docs.zaq.ai/api/auth", type: "html", depth_level: 2, tree_path: ["API", "Authentication"], parent_title: "API", metadata: ["selected", "included", "group: api", "parent: API"]}
        ]

      :investor ->
        [
          %{id: "investor-overview", title: "Overview", url: "https://investors.zaq.ai/overview", type: "html", depth_level: 1, tree_path: ["Approved", "Overview"], parent_title: "Approved", metadata: ["selected", "included", "group: approved", "parent: Approved"]},
          %{id: "investor-governance", title: "Governance", url: "https://investors.zaq.ai/governance", type: "html", depth_level: 1, tree_path: ["Approved", "Governance"], parent_title: "Approved", metadata: ["selected", "included", "group: approved", "parent: Approved"]},
          %{id: "investor-pdf", title: "Investor packet PDF", url: "https://investors.zaq.ai/files/investor-packet.pdf", type: "pdf", depth_level: 2, tree_path: ["Approved", "Files", "Investor packet PDF"], parent_title: "Files", metadata: ["selected", "included", "format: pdf", "parent: Files"]}
        ]

      :support ->
        [
          %{id: "support-faq", title: "FAQ home", url: "https://support.zaq.ai/faq", type: "html", depth_level: 1, tree_path: ["Support", "FAQ home"], parent_title: "Support", metadata: ["selected", "included", "group: support", "parent: Support"]},
          %{id: "support-api", title: "API support", url: "https://support.zaq.ai/articles/api-support", type: "html", depth_level: 2, tree_path: ["Support", "Articles", "API support"], parent_title: "Articles", metadata: ["selected", "included", "group: articles", "parent: Articles"]}
        ]
    end
  end

  defp knowledge_items(kind) do
    case kind do
      :marketing ->
        [
          %{title: "Homepage overview", source_url: "https://www.zaq.ai/", path: "web/crawled/marketing/home.md"},
          %{title: "Pricing page", source_url: "https://www.zaq.ai/pricing", path: "web/crawled/marketing/pricing.md"},
          %{title: "Knowledge base feature", source_url: "https://www.zaq.ai/product/knowledge-base", path: "web/crawled/marketing/product/knowledge-base.md"}
        ]

      :docs ->
        [
          %{title: "Getting started guide", source_url: "https://docs.zaq.ai/guides/getting-started", path: "web/crawled/docs/getting-started.md"},
          %{title: "Architecture", source_url: "https://docs.zaq.ai/architecture", path: "web/crawled/docs/architecture.md"},
          %{title: "Auth API", source_url: "https://docs.zaq.ai/api/auth", path: "web/crawled/docs/api/auth.md"}
        ]

      :investor ->
        [
          %{title: "Investor overview", source_url: "https://investors.zaq.ai/overview", path: "web/crawled/investor/overview.md"},
          %{title: "Governance", source_url: "https://investors.zaq.ai/governance", path: "web/crawled/investor/governance.md"}
        ]

      _ -> []
    end
  end
end
