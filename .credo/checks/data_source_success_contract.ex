defmodule Zaq.Credo.Check.Warning.DataSourceSuccessContract do
  @moduledoc """
  Enforces DataSource bridge success payload contract:

  - `{:ok, %Zaq.Contracts.RecordPage{...}}`
  - `{:ok, %Zaq.Contracts.Record{...}}`
  - `{:ok, map}` where the map wraps at least one `%Record{}` or `%RecordPage{}`
  """

  use Credo.Check,
    base_priority: :higher,
    category: :warning,
    explanations: [
      check:
        "DataSource bridge callbacks must return Record/RecordPage (directly or wrapped in a map) on success.",
      params: []
    ]

  alias Credo.SourceFile

  @impl true
  def run(%SourceFile{} = source_file, params) do
    if datasource_bridge_module?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> SourceFile.ast()
      |> collect_issues(issue_meta)
    else
      []
    end
  end

  defp datasource_bridge_module?(source_file) do
    source_file
    |> SourceFile.ast()
    |> case do
      {:ok, ast} -> has_datasource_behaviour?(ast)
      _ -> false
    end
  end

  defp has_datasource_behaviour?({:defmodule, _, [_, [do: body]]}) do
    {_ast, found?} =
      Macro.prewalk(body, false, fn
        {:@, _, [{:behaviour, _, [{:__aliases__, _, [:Zaq, :Channels, :DataSourceBridge]}]}]} =
            node,
        _acc ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp has_datasource_behaviour?(_), do: false

  defp collect_issues({:ok, ast}, issue_meta) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:def, _, _} = node, acc ->
          {node, acc ++ issues_for_def(node, issue_meta)}

        {:defp, _, _} = node, acc ->
          {node, acc ++ issues_for_def(node, issue_meta)}

        node, acc ->
          {node, acc}
      end)

    issues
  end

  defp collect_issues(_, _), do: []

  defp issues_for_def({_, _, [_, [do: body]]}, issue_meta) do
    {_ast, issues} =
      Macro.prewalk(body, [], fn
        {:ok, payload} = node, acc ->
          if valid_success_payload?(payload) do
            {node, acc}
          else
            issue =
              format_issue(issue_meta,
                message:
                  "Invalid DataSource success payload: expected %Record{}, %RecordPage{}, or a map wrapping one of them"
              )

            {node, [issue | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp issues_for_def(_, _), do: []

  defp valid_success_payload?({:%, _, [{:__aliases__, _, [:Zaq, :Contracts, :RecordPage]}, _]}),
    do: true

  defp valid_success_payload?({:%, _, [{:__aliases__, _, [:Zaq, :Contracts, :Record]}, _]}),
    do: true

  defp valid_success_payload?({:%{}, _, kv}) when is_list(kv) do
    Enum.any?(kv, fn
      {_, value} -> wrapped_record_or_page?(value)
      _ -> false
    end)
  end

  defp valid_success_payload?(_), do: false

  defp wrapped_record_or_page?({:%, _, [{:__aliases__, _, [:Zaq, :Contracts, :RecordPage]}, _]}),
    do: true

  defp wrapped_record_or_page?({:%, _, [{:__aliases__, _, [:Zaq, :Contracts, :Record]}, _]}),
    do: true

  defp wrapped_record_or_page?(_), do: false
end
