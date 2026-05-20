defmodule Zaq.Agent.Tools.Registry do
  @moduledoc """
  Whitelisted tool registry for BO-managed custom agents.

  This module is intentionally code-configured so runtime declarations cannot
  execute arbitrary modules.
  """

  @type descriptor :: %{
          required(:key) => String.t(),
          required(:label) => String.t(),
          required(:description) => String.t(),
          required(:module) => module()
        }

  @tools [
    %{
      key: "answering.search_knowledge_base",
      label: "Search knowledge base",
      description: "Search the ZAQ knowledge base with a refined query (answering-only)",
      module: Zaq.Agent.Tools.SearchKnowledgeBase
    },
    %{
      key: "answering.knowledge_base_overview",
      label: "Knowledge Base Overview",
      description:
        "Shows the user what documents exist in the knowledge base, how many are indexed, and their ingestion status — without reading document content (answering-only)",
      module: Zaq.Agent.Tools.KnowledgeBaseOverview
    },
    %{
      key: "data_source.get_document",
      label: "Get document",
      description: "Get a document by id from a specific datasource provider",
      module: Zaq.Agent.Tools.GetDocument
    },
    %{
      key: "data_source.list_documents",
      label: "List documents",
      description: "List document metadata in a specific path for a specific datasource provider",
      module: Zaq.Agent.Tools.ListDocuments
    },
    %{
      key: "data_source.search_documents",
      label: "Search documents",
      description: "Search document metadata for a specific datasource provider",
      module: Zaq.Agent.Tools.SearchDocuments
    },
    %{
      key: "data_source.download_document",
      label: "Download document",
      description: "Download a document and return a normalized record with content",
      module: Zaq.Agent.Tools.DownloadDocument
    },
    ## Requires permission
    # %{
    #   key: "files.read_file",
    #   label: "Read file",
    #   description: "Read file contents from a path",
    #   module: Jido.Tools.Files.ReadFile
    # },
    ## Requires permission
    # %{
    #   key: "files.write_file",
    #   label: "Write file",
    #   description: "Write content to a file path",
    #   module: Jido.Tools.Files.WriteFile
    # },
    ## Requires permission
    # %{
    #   key: "files.copy_file",
    #   label: "Copy file",
    #   description: "Copy a file to another path",
    #   module: Jido.Tools.Files.CopyFile
    # },
    ## Requires permission
    # %{
    #   key: "files.move_file",
    #   label: "Move file",
    #   description: "Move or rename a file path",
    #   module: Jido.Tools.Files.MoveFile
    # },
    ## Requires permission
    # %{
    #   key: "files.delete_file",
    #   label: "Delete file",
    #   description: "Delete a file or directory path",
    #   module: Jido.Tools.Files.DeleteFile
    # },
    # ## we need to see if we can call an action `ListDirectory` before doing it,
    # %{
    #   key: "files.make_directory",
    #   label: "Make directory",
    #   description: "Create a directory path",
    #   module: Jido.Tools.Files.MakeDirectory
    # },
    ## Requires permission
    # %{
    #   key: "files.list_directory",
    #   label: "List directory",
    #   description: "List entries in a directory path",
    #   module: Jido.Tools.Files.ListDirectory
    # },
    %{
      key: "basic.sleep",
      label: "Sleep",
      description: "Pause execution for a duration",
      module: Jido.Tools.Basic.Sleep
    },
    %{
      key: "basic.log",
      label: "Log",
      description: "Write a log message",
      module: Jido.Tools.Basic.Log
    },
    %{
      key: "basic.todo",
      label: "Todo",
      description: "Record a TODO note",
      module: Jido.Tools.Basic.Todo
    },
    %{
      key: "basic.random_sleep",
      label: "Random sleep",
      description: "Pause for a random duration",
      module: Jido.Tools.Basic.RandomSleep
    },
    %{
      key: "basic.increment",
      label: "Increment",
      description: "Increment a numeric value",
      module: Jido.Tools.Basic.Increment
    },
    %{
      key: "basic.decrement",
      label: "Decrement",
      description: "Decrement a numeric value",
      module: Jido.Tools.Basic.Decrement
    },
    %{
      key: "basic.noop",
      label: "Noop",
      description: "No operation",
      module: Jido.Tools.Basic.Noop
    },
    %{
      key: "basic.inspect",
      label: "Inspect",
      description: "Inspect and print a value",
      module: Jido.Tools.Basic.Inspect
    },
    %{
      key: "basic.today",
      label: "Today",
      description: "Get current date",
      module: Jido.Tools.Basic.Today
    },
    %{
      key: "arithmetic.add",
      label: "Add",
      description: "Add two numbers",
      module: Jido.Tools.Arithmetic.Add
    },
    %{
      key: "arithmetic.subtract",
      label: "Subtract",
      description: "Subtract two numbers",
      module: Jido.Tools.Arithmetic.Subtract
    },
    %{
      key: "arithmetic.multiply",
      label: "Multiply",
      description: "Multiply two numbers",
      module: Jido.Tools.Arithmetic.Multiply
    },
    %{
      key: "arithmetic.divide",
      label: "Divide",
      description: "Divide two numbers",
      module: Jido.Tools.Arithmetic.Divide
    },
    %{
      key: "arithmetic.square",
      label: "Square",
      description: "Square a number",
      module: Jido.Tools.Arithmetic.Square
    },
    %{
      key: "advanced.lua_eval",
      label: "Lua eval",
      description: "Evaluate Lua code in a sandbox",
      module: Jido.Tools.LuaEval
    }
  ]

  @spec tools() :: [descriptor()]
  def tools, do: @tools

  @spec keys() :: [String.t()]
  def keys, do: Enum.map(@tools, & &1.key)

  @spec valid_tool_key?(String.t()) :: boolean()
  def valid_tool_key?(tool_key) when is_binary(tool_key),
    do: Enum.any?(@tools, &(&1.key == tool_key))

  def valid_tool_key?(_), do: false

  @doc """
  Returns the subset of `keys` that are no longer registered in `@tools`.

  Useful for detecting saved tool references that became stale after a tool was removed
  from the registry.
  """
  @spec ghost_keys([String.t()]) :: [String.t()]
  def ghost_keys(keys) when is_list(keys), do: Enum.reject(keys, &valid_tool_key?/1)
  def ghost_keys(_), do: []

  @spec resolve_modules([String.t()]) ::
          {:ok, [module()]} | {:error, {:unknown_tools, [String.t()]}}
  def resolve_modules(tool_keys) when is_list(tool_keys) do
    by_key = Map.new(@tools, &{&1.key, &1.module})

    {modules, unknown} =
      Enum.reduce(tool_keys, {[], []}, fn key, {mods, missing} ->
        case Map.fetch(by_key, key) do
          {:ok, module} -> {[module | mods], missing}
          :error -> {mods, [key | missing]}
        end
      end)

    case unknown do
      [] -> {:ok, modules |> Enum.reverse() |> Enum.uniq()}
      missing -> {:error, {:unknown_tools, Enum.reverse(missing)}}
    end
  end

  def resolve_modules(_), do: {:error, {:unknown_tools, []}}

  @doc """
  Returns model tool-calling support from LLMDB.

  Tool support is explicit: unknown/missing provider or model is treated as not
  supporting tools.
  """
  @spec model_supports_tools?(String.t() | nil, String.t() | nil) :: boolean()
  def model_supports_tools?(provider_id, model_id)

  def model_supports_tools?(provider_id, model_id)
      when provider_id in [nil, "", "custom"] or model_id in [nil, ""] do
    false
  end

  def model_supports_tools?(provider_id, model_id)
      when is_binary(provider_id) and is_binary(model_id) do
    with provider_atom when not is_nil(provider_atom) <- provider_atom_from_id(provider_id),
         {:ok, %{capabilities: capabilities}} <- LLMDB.model(provider_atom, model_id),
         tools when is_map(tools) <- Map.get(capabilities || %{}, :tools) do
      map_size(tools) > 0
    else
      _ -> false
    end
  end

  defp provider_atom_from_id(provider_id) when is_binary(provider_id) do
    downcased = String.downcase(provider_id)

    Enum.find_value(LLMDB.providers(), fn provider ->
      if Atom.to_string(provider.id) == downcased, do: provider.id
    end)
  end
end
