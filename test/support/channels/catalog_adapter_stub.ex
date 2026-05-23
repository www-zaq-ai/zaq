defmodule Zaq.Test.Channels.CatalogAdapterStub do
  @moduledoc false

  @action_suffixes %{
    {"file", "list"} => "files.list",
    {"permission", "list"} => "permissions.list",
    {"file", "get"} => "file.get",
    {"file", "search"} => "files.search",
    {"file", "create"} => "file.create",
    {"file", "update"} => "file.update",
    {"file", "delete"} => "file.delete"
  }

  def tools(opts) when is_list(opts) do
    provider = Keyword.fetch!(opts, :provider)
    tool_type = Keyword.get(opts, :type)

    with {:ok, integration} <- integration_for(provider),
         {:ok, actions} <- legacy_module().actions(integration) do
      triggers = load_triggers(integration)

      (Enum.map(List.wrap(actions), &normalize_action(&1, provider)) ++
         Enum.map(List.wrap(triggers), &normalize_trigger(&1, provider)))
      |> maybe_filter_tools_by_type(tool_type)
    else
      {:error, _} = error -> error
    end
  catch
    {:error, _} = error -> error
  end

  defp maybe_filter_tools_by_type(tools, nil), do: tools

  defp maybe_filter_tools_by_type(tools, type) when is_list(tools) do
    Enum.filter(tools, fn tool ->
      Map.get(tool, :type) == type or Map.get(tool, "type") == type
    end)
  end

  def describe_tool({provider, id}, _opts) do
    with {:ok, integration} <- integration_for(provider),
         {:ok, actions} <- legacy_module().actions(integration),
         action when is_map(action) <-
           Enum.find(actions, &(canonical_action_id(&1, provider) == id)) do
      {:ok, %{input: Map.get(action, :input, [])}}
    else
      _ -> {:error, :unsupported}
    end
  end

  def call_tool({provider, id}, params, opts) do
    with {:ok, integration} <- integration_for(provider),
         {:ok, actions} <- legacy_module().actions(integration),
         action when is_map(action) <-
           Enum.find(actions, &(canonical_action_id(&1, provider) == id)) do
      legacy_module().invoke(integration, Map.get(action, :id), params, opts)
    else
      _ -> {:error, :unsupported}
    end
  end

  defp integration_for(provider) do
    provider_key =
      provider
      |> to_string()
      |> String.replace(".", "_")
      |> String.to_atom()

    case get_in(Application.get_env(:zaq, :channels, %{}), [provider_key, :integration]) do
      integration when is_atom(integration) -> {:ok, integration}
      _ -> {:error, :unsupported}
    end
  end

  defp normalize_action(action, provider) do
    provider_key = provider_key(provider)

    action
    |> Map.new()
    |> Map.put(:id, canonical_action_id(action, provider))
    |> Map.put_new(:provider, provider_key)
    |> Map.put_new(:type, :action)
  end

  defp canonical_action_id(action, provider) do
    prefix = provider |> to_string() |> String.replace("_", ".")
    legacy_id = Map.get(action, :id) || Map.get(action, "id")

    if is_binary(legacy_id) and String.contains?(legacy_id, ".") do
      "#{prefix}.#{legacy_id_suffix(legacy_id)}"
    else
      "#{prefix}.#{action_suffix(action)}"
    end
  end

  defp legacy_id_suffix(legacy_id) do
    case String.split(legacy_id, ".", parts: 2) do
      [_, suffix] -> normalize_legacy_suffix(suffix)
      _ -> legacy_id
    end
  end

  defp normalize_legacy_suffix("files.get"), do: "file.get"
  defp normalize_legacy_suffix(suffix), do: suffix

  defp action_suffix(action) do
    resource = (Map.get(action, :resource) || "resource") |> to_string()
    verb = (Map.get(action, :verb) || "verb") |> to_string()

    Map.get(@action_suffixes, {resource, verb}, "#{resource}.#{verb}")
  end

  defp normalize_trigger(trigger, provider) do
    provider_key = provider_key(provider)
    trigger_kind = normalize_atom(Map.get(trigger, :kind) || Map.get(trigger, "kind"))
    verb = normalize_atom(Map.get(trigger, :verb) || Map.get(trigger, "verb"))

    trigger
    |> Map.new()
    |> Map.put(:provider, provider_key)
    |> Map.put_new(:type, :trigger)
    |> Map.put(:verb, verb)
    |> Map.put(:kind, trigger_kind)
    |> Map.put(:trigger_kind, trigger_kind)
  end

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> String.to_atom(trimmed)
    end
  end

  defp normalize_atom(_), do: nil

  defp provider_key(provider) do
    provider
    |> to_string()
    |> String.replace(".", "_")
    |> String.to_atom()
  end

  defp legacy_module,
    do: Application.get_env(:zaq, :jido_connect_bridge_jido_connect_module)

  defp load_triggers(integration) do
    if function_exported?(legacy_module(), :triggers, 1) do
      normalize_triggers_result(legacy_module().triggers(integration))
    else
      []
    end
  end

  defp normalize_triggers_result({:ok, list}) when is_list(list), do: list
  defp normalize_triggers_result({:error, _} = error), do: throw(error)
  defp normalize_triggers_result(_), do: []
end
