defmodule Zaq.Channels.ProviderCatalog do
  @moduledoc """
  Centralized provider metadata for Channels and Data Sources.
  """

  @file_capabilities [
    :list_items,
    :count_items,
    :list_principals,
    :count_principals,
    :get_item_metadata,
    :list_item_versions,
    :download_items,
    :export_items,
    :get_export_options,
    :create_item,
    :update_item,
    :delete_item,
    :search_items
  ]

  @sheet_capabilities [
    :sheet_inspect,
    :sheet_get,
    :sheet_create,
    :sheet_add_tab,
    :sheet_update_values,
    :sheet_append_values,
    :sheet_clear_values,
    :sheet_delete_tab
  ]

  @labels %{
    "zaq_local" => "ZAQ Local",
    "google_drive" => "Google Drive",
    "sharepoint" => "SharePoint"
  }

  @root_folder_defaults %{
    "google_drive" => "root",
    "sharepoint" => "/",
    "zaq_local" => "/"
  }

  @spec label(String.t()) :: String.t()
  def label(provider) when is_binary(provider) do
    Map.get(@labels, provider, provider |> String.replace("_", " ") |> String.capitalize())
  end

  @spec root_folder_default(String.t()) :: String.t()
  def root_folder_default(provider) when is_binary(provider) do
    Map.get(@root_folder_defaults, provider, "root")
  end

  @spec credential_provider(String.t()) :: String.t()
  def credential_provider("zaq_local"), do: "local_filesystem"
  def credential_provider(provider) when is_binary(provider), do: provider

  @spec credential_request_format(String.t()) :: String.t()
  def credential_request_format(_provider), do: "bearer"

  @spec oauth_module(String.t()) :: {:ok, module()} | {:error, term()}
  def oauth_module("google_drive"), do: {:ok, Jido.Connect.Google.OAuth}

  def oauth_module(provider) when is_binary(provider), do: {:error, :unsupported}

  @spec connector_provider_for_capability(String.t(), atom()) :: atom()
  def connector_provider_for_capability("google_drive", capability)
      when capability in @sheet_capabilities,
      do: :google_sheets

  def connector_provider_for_capability("google_drive", capability)
      when capability in @file_capabilities,
      do: :google_drive

  def connector_provider_for_capability(provider, _capability) when is_binary(provider),
    do: provider |> String.trim() |> String.to_atom()

  @spec capability_action_suffixes(atom()) :: [String.t()]
  def capability_action_suffixes(:list_items), do: ["files.list", "file.list"]
  def capability_action_suffixes(:list_principals), do: ["permissions.list", "permission.list"]
  def capability_action_suffixes(:get_item_metadata), do: ["file.get"]
  def capability_action_suffixes(:list_item_versions), do: ["revisions.list", "revision.list"]
  def capability_action_suffixes(:download_items), do: ["file.download"]
  def capability_action_suffixes(:export_items), do: ["file.export"]
  def capability_action_suffixes(:get_export_options), do: ["about.get"]
  def capability_action_suffixes(:create_item), do: ["file.create"]
  def capability_action_suffixes(:update_item), do: ["file.update"]
  def capability_action_suffixes(:delete_item), do: ["file.delete"]
  def capability_action_suffixes(:search_items), do: ["files.search", "file.search", "files.list"]

  def capability_action_suffixes(:sheet_inspect), do: ["spreadsheet.get"]
  def capability_action_suffixes(:sheet_get), do: ["values.get"]
  def capability_action_suffixes(:sheet_create), do: ["spreadsheet.create"]
  def capability_action_suffixes(:sheet_add_tab), do: ["sheet.add"]

  def capability_action_suffixes(:sheet_update_values),
    do: ["values.update", "values.batch_update"]

  def capability_action_suffixes(:sheet_append_values), do: ["values.append"]
  def capability_action_suffixes(:sheet_clear_values), do: ["values.clear", "values.batch_clear"]
  def capability_action_suffixes(:sheet_delete_tab), do: ["sheet.delete"]
  def capability_action_suffixes(_capability), do: []
end
