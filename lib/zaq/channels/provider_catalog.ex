defmodule Zaq.Channels.ProviderCatalog do
  @moduledoc """
  Centralized provider metadata for Channels and Data Sources.
  """

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
end
