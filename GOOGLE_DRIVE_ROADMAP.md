# Google Drive Ingestion Channel - Implementation Roadmap

## Overview

This roadmap outlines the implementation of a Google Drive ingestion channel for the Zaq platform, following the existing `Zaq.Engine.IngestionChannel` behaviour contract and integrating with the established UI patterns.

---

## Phase 1: Core Protocol & Infrastructure

### 1.1 Database Schema Extensions

**New Migration: `add_google_drive_fields_to_channel_configs`**

```elixir
# priv/repo/migrations/XXX_add_google_drive_fields_to_channel_configs.exs

defmodule Zaq.Repo.Migrations.AddGoogleDriveFieldsToChannelConfigs do
  use Ecto.Migration

  def change do
    alter table(:channel_configs) do
      # OAuth2 credentials (encrypted)
      add :client_id, :string
      add :client_secret, :string
      add :refresh_token, :text
      add :access_token, :text
      add :token_expires_at, :utc_datetime

      # Drive-specific settings (JSONB for flexibility)
      add :settings, :map, default: %{}
    end

    # Table for watched folders
    create table(:ingestion_watched_folders, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :channel_config_id, references(:channel_configs, on_delete: :delete_all), null: false
      add :provider_folder_id, :string, null: false  # Google Drive file ID
      add :folder_name, :string, null: false
      add :path, :string  # Human-readable path
      add :include_subfolders, :boolean, default: true
      add :file_types, {:array, :string}, default: []  # ["pdf", "docx", ...]
      add :last_synced_at, :utc_datetime
      add :watch_channel_id, :string  # Google Watch API channel ID
      add :watch_expiration, :utc_datetime
      add :webhook_url, :string
      add :active, :boolean, default: true

      timestamps()
    end

    create index(:ingestion_watched_folders, [:channel_config_id])
    create index(:ingestion_watched_folders, [:provider_folder_id])
    create unique_index(:ingestion_watched_folders, [:channel_config_id, :provider_folder_id])

    # Table for ingestion events/changes
    create table(:ingestion_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :watched_folder_id, references(:ingestion_watched_folders, on_delete: :delete_all)
      add :provider_file_id, :string, null: false
      add :file_name, :string
      add :event_type, :string, null: false  # "created", "modified", "deleted"
      add :mime_type, :string
      add :processed_at, :utc_datetime
      add :status, :string, default: "pending"  # "pending", "processing", "completed", "failed"
      add :error_message, :text
      add :metadata, :map, default: %{}  # File metadata from Drive

      timestamps()
    end

    create index(:ingestion_events, [:watched_folder_id])
    create index(:ingestion_events, [:provider_file_id])
    create index(:ingestion_events, [:status])
    create index(:ingestion_events, [:inserted_at])
  end
end
```

### 1.2 Schema Definitions

**`Zaq.Ingestion.WatchedFolder`**

```elixir
defmodule Zaq.Ingestion.WatchedFolder do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "ingestion_watched_folders" do
    belongs_to :channel_config, Zaq.Channels.ChannelConfig
    field :provider_folder_id, :string
    field :folder_name, :string
    field :path, :string
    field :include_subfolders, :boolean, default: true
    field :file_types, {:array, :string}, default: []
    field :last_synced_at, :utc_datetime
    field :watch_channel_id, :string
    field :watch_expiration, :utc_datetime
    field :webhook_url, :string
    field :active, :boolean, default: true

    has_many :ingestion_events, Zaq.Ingestion.IngestionEvent

    timestamps()
  end

  def changeset(folder, attrs) do
    folder
    |> cast(attrs, [
      :channel_config_id, :provider_folder_id, :folder_name, :path,
      :include_subfolders, :file_types, :last_synced_at, :watch_channel_id,
      :watch_expiration, :webhook_url, :active
    ])
    |> validate_required([:channel_config_id, :provider_folder_id, :folder_name])
    |> foreign_key_constraint(:channel_config_id)
    |> unique_constraint([:channel_config_id, :provider_folder_id])
  end
end
```

**`Zaq.Ingestion.IngestionEvent`**

```elixir
defmodule Zaq.Ingestion.IngestionEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "ingestion_events" do
    belongs_to :watched_folder, Zaq.Ingestion.WatchedFolder
    field :provider_file_id, :string
    field :file_name, :string
    field :event_type, :string  # "created", "modified", "deleted"
    field :mime_type, :string
    field :processed_at, :utc_datetime
    field :status, :string, default: "pending"
    field :error_message, :text
    field :metadata, :map, default: %{}

    timestamps()
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :watched_folder_id, :provider_file_id, :file_name, :event_type,
      :mime_type, :processed_at, :status, :error_message, :metadata
    ])
    |> validate_required([:watched_folder_id, :provider_file_id, :event_type])
    |> validate_inclusion(:event_type, ["created", "modified", "deleted"])
    |> validate_inclusion(:status, ["pending", "processing", "completed", "failed"])
  end
end
```

### 1.3 Context Module

**`Zaq.Ingestion`** extensions:

```elixir
defmodule Zaq.Ingestion do
  # ... existing code ...

  # Watched Folders
  alias Zaq.Ingestion.WatchedFolder

  def list_watched_folders(channel_config_id) do
    WatchedFolder
    |> where([w], w.channel_config_id == ^channel_config_id)
    |> Repo.all()
  end

  def get_watched_folder!(id), do: Repo.get!(WatchedFolder, id)

  def create_watched_folder(attrs) do
    %WatchedFolder{}
    |> WatchedFolder.changeset(attrs)
    |> Repo.insert()
  end

  def update_watched_folder(%WatchedFolder{} = folder, attrs) do
    folder
    |> WatchedFolder.changeset(attrs)
    |> Repo.update()
  end

  def delete_watched_folder(%WatchedFolder{} = folder) do
    Repo.delete(folder)
  end

  def change_watched_folder(%WatchedFolder{} = folder, attrs \\ %{}) do
    WatchedFolder.changeset(folder, attrs)
  end

  # Ingestion Events
  alias Zaq.Ingestion.IngestionEvent

  def list_pending_events(limit \\ 100) do
    IngestionEvent
    |> where([e], e.status == "pending")
    |> order_by([e], asc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def create_ingestion_event(attrs) do
    %IngestionEvent{}
    |> IngestionEvent.changeset(attrs)
    |> Repo.insert()
  end

  def mark_event_processing(event_id) do
    IngestionEvent
    |> where([e], e.id == ^event_id)
    |> Repo.update_all(set: [status: "processing", updated_at: DateTime.utc_now()])
  end

  def mark_event_completed(event_id) do
    IngestionEvent
    |> where([e], e.id == ^event_id)
    |> Repo.update_all(set: [status: "completed", processed_at: DateTime.utc_now(), updated_at: DateTime.utc_now()])
  end

  def mark_event_failed(event_id, error_message) do
    IngestionEvent
    |> where([e], e.id == ^event_id)
    |> Repo.update_all(set: [status: "failed", error_message: error_message, updated_at: DateTime.utc_now()])
  end
end
```

---

## Phase 2: Google Drive API Integration

### 2.1 Google Drive API Client

**`Zaq.Channels.Ingestion.GoogleDrive.API`**

```elixir
defmodule Zaq.Channels.Ingestion.GoogleDrive.API do
  @moduledoc """
  Google Drive REST API client using Req.
  Handles authentication, rate limiting, and file operations.
  """

  require Logger

  @base_url "https://www.googleapis.com/drive/v3"
  @upload_url "https://www.googleapis.com/upload/drive/v3"
  @auth_url "https://oauth2.googleapis.com/token"

  # Supported MIME types for export
  @export_formats %{
    "application/vnd.google-apps.document" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.google-apps.spreadsheet" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "application/vnd.google-apps.presentation" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "application/vnd.google-apps.drawing" => "image/png"
  }

  @supported_mime_types [
    "application/pdf",
    "text/plain",
    "text/markdown",
    "image/jpeg",
    "image/png",
    "image/gif",
    "image/webp",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "application/msword",
    "application/vnd.ms-excel",
    "application/vnd.ms-powerpoint"
  ] ++ Map.keys(@export_formats)

  def supported_mime_types, do: @supported_mime_types

  # Authentication

  def refresh_access_token(%{refresh_token: refresh_token, client_id: client_id, client_secret: client_secret}) do
    body = %{
      refresh_token: refresh_token,
      client_id: client_id,
      client_secret: client_secret,
      grant_type: "refresh_token"
    }

    case Req.post(
           url: @auth_url,
           form: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token, "expires_in" => expires_in}}} ->
        expires_at = DateTime.utc_now() |> DateTime.add(expires_in, :second)
        {:ok, %{access_token: token, expires_at: expires_at}}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("[GoogleDrive.API] Token refresh failed: #{status} - #{inspect(body)}")
        {:error, :token_refresh_failed}

      {:error, reason} ->
        Logger.error("[GoogleDrive.API] Token refresh error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def ensure_valid_token(config) do
    if token_expired?(config) do
      case refresh_access_token(config) do
        {:ok, %{access_token: token, expires_at: expires_at}} ->
          updated_config = %{config | access_token: token, token_expires_at: expires_at}
          # Persist updated token
          Zaq.Channels.update_channel_config(config, %{
            access_token: token,
            token_expires_at: expires_at
          })
          {:ok, updated_config}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, config}
    end
  end

  defp token_expired?(%{token_expires_at: nil}), do: true
  defp token_expired?(%{token_expires_at: expires_at}) do
    DateTime.diff(expires_at, DateTime.utc_now(), :second) < 300  # Refresh 5 min before expiry
  end

  # File Operations

  def list_files(config, folder_id, opts \\ []) do
    with {:ok, config} <- ensure_valid_token(config) do
      query = build_files_query(folder_id, opts)
      fields = "nextPageToken,files(id,name,mimeType,modifiedTime,size,md5Checksum,webViewLink,parents)"

      do_list_files(config, query, fields, opts[:page_token], [])
    end
  end

  defp do_list_files(config, query, fields, page_token, acc) do
    params = [
      q: query,
      fields: fields,
      pageSize: 100,
      spaces: "drive"
    ]
    |> maybe_put(:pageToken, page_token)

    case drive_request(config, :get, "/files", params: params) do
      {:ok, %Req.Response{status: 200, body: %{"files" => files, "nextPageToken" => next_token}}} ->
        do_list_files(config, query, fields, next_token, acc ++ files)

      {:ok, %Req.Response{status: 200, body: %{"files" => files}}} ->
        {:ok, acc ++ files}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_files_query(folder_id, opts) do
    base_query = "'#{folder_id}' in parents"
    
    type_filter = 
      if opts[:include_folders] do
        ""
      else
        " and mimeType != 'application/vnd.google-apps.folder'"
      end

    mime_filter =
      if opts[:mime_types] do
        mime_conditions = Enum.map_join(opts[:mime_types], " or ", fn mime -> "mimeType='#{mime}'" end)
        " and (#{mime_conditions})"
      else
        supported_mimes = Enum.map_join(@supported_mime_types, " or ", fn mime -> "mimeType='#{mime}'" end)
        " and (#{supported_mimes})"
      end

    "#{base_query}#{type_filter}#{mime_filter} and trashed=false"
  end

  def get_file(config, file_id) do
    with {:ok, config} <- ensure_valid_token(config) do
      fields = "id,name,mimeType,modifiedTime,size,md5Checksum,webViewLink,parents,createdTime,lastModifyingUser"
      
      case drive_request(config, :get, "/files/#{file_id}", params: [fields: fields]) do
        {:ok, %Req.Response{status: 200, body: file}} ->
          {:ok, file}

        {:ok, %Req.Response{status: 404}} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def download_file(config, file_id, mime_type) do
    with {:ok, config} <- ensure_valid_token(config) do
      cond do
        Map.has_key?(@export_formats, mime_type) ->
          export_format = @export_formats[mime_type]
          url = "#{@base_url}/files/#{file_id}/export?mimeType=#{URI.encode_www_form(export_format)}"
          download_with_auth(config, url)

        true ->
          url = "#{@base_url}/files/#{file_id}?alt=media"
          download_with_auth(config, url)
      end
    end
  end

  defp download_with_auth(config, url) do
    case Req.get(
           url: url,
           headers: [{"authorization", "Bearer #{config.access_token}"}],
           receive_timeout: 120_000
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("[GoogleDrive.API] Download failed: #{status} - #{inspect(body)}")
        {:error, :download_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Watch API (Push Notifications)

  def create_watch_channel(config, folder_id, webhook_url) do
    with {:ok, config} <- ensure_valid_token(config) do
      body = %{
        id: generate_channel_id(),
        type: "web_hook",
        address: webhook_url,
        expiration: DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.to_unix(:millisecond)
      }

      case drive_request(config, :post, "/files/#{folder_id}/watch", json: body) do
        {:ok, %Req.Response{status: 200, body: response}} ->
          {:ok, %{
            channel_id: response["id"],
            resource_id: response["resourceId"],
            expiration: DateTime.from_unix!(response["expiration"], :millisecond)
          }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def stop_watch_channel(config, channel_id, resource_id) do
    with {:ok, config} <- ensure_valid_token(config) do
      body = %{
        id: channel_id,
        resourceId: resource_id
      }

      case drive_request(config, :post, "/channels/stop", json: body) do
        {:ok, %Req.Response{status: 204}} ->
          :ok

        {:ok, %Req.Response{status: status}} ->
          Logger.warning("[GoogleDrive.API] Stop watch returned #{status}")
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Folder Operations

  def list_folders(config, parent_id \\ "root") do
    with {:ok, config} <- ensure_valid_token(config) do
      query = "'#{parent_id}' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false"
      fields = "files(id,name,modifiedTime)"

      case drive_request(config, :get, "/files", params: [q: query, fields: fields, pageSize: 100]) do
        {:ok, %Req.Response{status: 200, body: %{"files" => folders}}} ->
          {:ok, folders}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def get_folder_path(config, folder_id) do
    with {:ok, config} <- ensure_valid_token(config) do
      build_folder_path(config, folder_id, [])
    end
  end

  defp build_folder_path(_config, "root", acc), do: {:ok, Enum.join(["My Drive" | acc], " / ")}
  defp build_folder_path(config, folder_id, acc) do
    case drive_request(config, :get, "/files/#{folder_id}", params: [fields: "name,parents"]) do
      {:ok, %Req.Response{status: 200, body: %{"name" => name, "parents" => [parent_id | _]}}} ->
        build_folder_path(config, parent_id, [name | acc])

      {:ok, %Req.Response{status: 200, body: %{"name" => name}}} ->
        {:ok, Enum.join(["My Drive", name | acc], " / ")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private Helpers

  defp drive_request(config, method, path, opts \\ []) do
    url = @base_url <> path
    headers = [{"authorization", "Bearer #{config.access_token}"}]

    req_opts = [
      method: method,
      url: url,
      headers: headers
    ] ++ opts

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: 401}} ->
        # Token might be expired, try refreshing once
        case refresh_access_token(config) do
          {:ok, %{access_token: new_token}} ->
            updated_config = %{config | access_token: new_token}
            # Retry with new token
            retry_request(updated_config, method, path, opts)

          {:error, reason} ->
            {:error, reason}
        end

      result ->
        result
    end
  end

  defp retry_request(config, method, path, opts) do
    url = @base_url <> path
    headers = [{"authorization", "Bearer #{config.access_token}"}]

    req_opts = [
      method: method,
      url: url,
      headers: headers
    ] ++ opts

    Req.request(req_opts)
  end

  defp generate_channel_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp maybe_put(list, _key, nil), do: list
  defp maybe_put(list, key, value), do: [{key, value} | list]
end
```

### 2.2 IngestionChannel Behaviour Implementation

**`Zaq.Channels.Ingestion.GoogleDrive`**

```elixir
defmodule Zaq.Channels.Ingestion.GoogleDrive do
  @moduledoc """
  Google Drive ingestion channel implementation.
  Follows the Zaq.Engine.IngestionChannel behaviour.
  """

  @behaviour Zaq.Engine.IngestionChannel

  require Logger

  alias Zaq.Channels.Ingestion.GoogleDrive.API
  alias Zaq.Ingestion.{WatchedFolder, IngestionEvent}

  @impl true
  def connect(%Zaq.Channels.ChannelConfig{} = config) do
    # Validate required OAuth fields
    if missing_credentials?(config) do
      {:error, :missing_credentials}
    else
      # Test connection by listing root folder
      case API.list_folders(config, "root") do
        {:ok, _folders} ->
          state = %{
            config: config,
            connected: true,
            watched_folders: load_watched_folders(config.id)
          }
          {:ok, state}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def disconnect(state) do
    # Stop all watch channels
    Enum.each(state.watched_folders, fn folder ->
      if folder.watch_channel_id do
        API.stop_watch_channel(state.config, folder.watch_channel_id, folder.provider_folder_id)
      end
    end)

    {:ok, %{state | connected: false}}
  end

  @impl true
  def list_documents(state, opts \\ []) do
    folder_id = opts[:folder_id] || "root"
    
    case API.list_files(state.config, folder_id, include_folders: true) do
      {:ok, files} ->
        documents = Enum.map(files, &file_to_document/1)
        {:ok, documents}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch_document(%{provider_file_id: file_id, mime_type: mime_type}, state) do
    case API.download_file(state.config, file_id, mime_type) do
      {:ok, content} ->
        {:ok, content}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def schedule_sync(config) do
    # Create Oban job for periodic sync
    %{channel_config_id: config.id}
    |> Zaq.Channels.Ingestion.GoogleDrive.SyncWorker.new()
    |> Oban.insert()
  end

  @impl true
  def handle_event(%{"kind" => "drive#change"} = change_event, state) do
    # Handle Google Drive push notification
    file_id = change_event["fileId"]
    change_type = change_event["changeType"]  # "file" or "teamDrive"
    
    Logger.info("[GoogleDrive] Received change notification for file #{file_id}")

    # Find which watched folder this file belongs to
    case find_watched_folder_for_file(state, file_id) do
      {:ok, folder} ->
        # Get file details
        case API.get_file(state.config, file_id) do
          {:ok, file} ->
            event_type = determine_event_type(file, change_event)
            
            # Create ingestion event
            {:ok, _event} = Zaq.Ingestion.create_ingestion_event(%{
              watched_folder_id: folder.id,
              provider_file_id: file_id,
              file_name: file["name"],
              event_type: event_type,
              mime_type: file["mimeType"],
              status: "pending",
              metadata: %{
                size: file["size"],
                modified_time: file["modifiedTime"],
                web_view_link: file["webViewLink"]
              }
            })

            # Trigger processing
            process_pending_events()
            :ok

          {:error, :not_found} ->
            # File was deleted
            {:ok, _event} = Zaq.Ingestion.create_ingestion_event(%{
              watched_folder_id: folder.id,
              provider_file_id: file_id,
              event_type: "deleted",
              status: "pending"
            })
            process_pending_events()
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      :not_found ->
        Logger.warning("[GoogleDrive] File #{file_id} not in any watched folder")
        :ok
    end
  end

  def handle_event(_event, _state) do
    :ok
  end

  # Public API for folder management

  def add_watched_folder(config, folder_id, opts \\ []) do
    # Get folder details
    case API.get_file(config, folder_id) do
      {:ok, file} when file["mimeType"] == "application/vnd.google-apps.folder" ->
        # Get full path
        {:ok, path} = API.get_folder_path(config, folder_id)

        # Create watch channel if webhook URL provided
        watch_info = 
          if opts[:webhook_url] do
            case API.create_watch_channel(config, folder_id, opts[:webhook_url]) do
              {:ok, info} -> info
              {:error, _} -> nil
            end
          end

        attrs = %{
          channel_config_id: config.id,
          provider_folder_id: folder_id,
          folder_name: file["name"],
          path: path,
          include_subfolders: opts[:include_subfolders] || true,
          file_types: opts[:file_types] || [],
          webhook_url: opts[:webhook_url],
          watch_channel_id: watch_info[:channel_id],
          watch_expiration: watch_info[:expiration],
          active: true
        }

        Zaq.Ingestion.create_watched_folder(attrs)

      {:ok, _} ->
        {:error, :not_a_folder}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def remove_watched_folder(config, watched_folder) do
    # Stop watch channel
    if watched_folder.watch_channel_id do
      API.stop_watch_channel(config, watched_folder.watch_channel_id, watched_folder.provider_folder_id)
    end

    Zaq.Ingestion.delete_watched_folder(watched_folder)
  end

  def sync_folder(config, watched_folder) do
    Logger.info("[GoogleDrive] Starting sync for folder #{watched_folder.folder_name}")

    opts = [
      include_folders: false,
      mime_types: supported_mime_types(watched_folder.file_types)
    ]

    case API.list_files(config, watched_folder.provider_folder_id, opts) do
      {:ok, files} ->
        Enum.each(files, fn file ->
          {:ok, _event} = Zaq.Ingestion.create_ingestion_event(%{
            watched_folder_id: watched_folder.id,
            provider_file_id: file["id"],
            file_name: file["name"],
            event_type: "created",
            mime_type: file["mimeType"],
            status: "pending",
            metadata: %{
              size: file["size"],
              modified_time: file["modifiedTime"],
              web_view_link: file["webViewLink"]
            }
          })
        end)

        # Update last_synced_at
        Zaq.Ingestion.update_watched_folder(watched_folder, %{last_synced_at: DateTime.utc_now()})

        # Trigger processing
        process_pending_events()

        {:ok, length(files)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  defp missing_credentials?(config) do
    is_nil(config.refresh_token) or is_nil(config.client_id) or is_nil(config.client_secret)
  end

  defp load_watched_folders(channel_config_id) do
    Zaq.Ingestion.list_watched_folders(channel_config_id)
  end

  defp file_to_document(file) do
    %{
      id: file["id"],
      name: file["name"],
      mime_type: file["mimeType"],
      modified_time: file["modifiedTime"],
      size: file["size"],
      is_folder: file["mimeType"] == "application/vnd.google-apps.folder",
      provider_file_id: file["id"]
    }
  end

  defp find_watched_folder_for_file(state, file_id) do
    # Get file details to find its parent folders
    case API.get_file(state.config, file_id) do
      {:ok, file} ->
        parents = file["parents"] || []
        
        # Find watched folder that contains this file
        Enum.find_value(state.watched_folders, :not_found, fn folder ->
          if folder.provider_folder_id in parents or folder.provider_folder_id == file_id do
            {:ok, folder}
          else
            # Check subfolders if include_subfolders is true
            if folder.include_subfolders do
              # Check if any parent is within the watched folder
              if Enum.any?(parents, &parent_in_folder?(&1, folder, state.config)) do
                {:ok, folder}
              end
            end
          end
        end)

      {:error, _} ->
        :not_found
    end
  end

  defp parent_in_folder?(parent_id, folder, config) do
    # Recursively check if parent_id is within the watched folder
    case API.get_file(config, parent_id) do
      {:ok, file} ->
        parents = file["parents"] || []
        
        if folder.provider_folder_id in parents do
          true
        else
          Enum.any?(parents, &parent_in_folder?(&1, folder, config))
        end

      {:error, _} ->
        false
    end
  end

  defp determine_event_type(file, change_event) do
    # Logic to determine if file is new or modified
    # Could check against existing documents in DB
    if change_event["removed"] do
      "deleted"
    else
      # Check if we already have this file
      case Zaq.Repo.get_by(Zaq.Ingestion.Document, source: "google_drive:#{file["id"]}") do
        nil -> "created"
        existing -> 
          if existing.metadata["modified_time"] != file["modifiedTime"] do
            "modified"
          else
            "created"
          end
      end
    end
  end

  defp supported_mime_types([]), do: API.supported_mime_types()
  defp supported_mime_types(types), do: types

  defp process_pending_events do
    # Trigger Oban job to process events
    %{}
    |> Zaq.Channels.Ingestion.GoogleDrive.EventWorker.new()
    |> Oban.insert()
  end
end
```

### 2.3 Background Workers

**`Zaq.Channels.Ingestion.GoogleDrive.EventWorker`**

```elixir
defmodule Zaq.Channels.Ingestion.GoogleDrive.EventWorker do
  @moduledoc """
  Processes Google Drive ingestion events (file changes).
  """

  use Oban.Worker,
    queue: :ingestion,
    max_attempts: 3,
    unique: [period: 60, fields: [:args]]

  require Logger

  alias Zaq.Ingestion
  alias Zaq.Channels.Ingestion.GoogleDrive.API

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    events = Ingestion.list_pending_events(50)
    
    Enum.each(events, fn event ->
      Ingestion.mark_event_processing(event.id)
      
      case process_event(event) do
        :ok ->
          Ingestion.mark_event_completed(event.id)
          
        {:error, reason} ->
          Ingestion.mark_event_failed(event.id, inspect(reason))
      end
    end)

    # If there are more pending events, schedule another job
    if length(events) == 50 do
      %{}
      |> __MODULE__.new()
      |> Oban.insert()
    end

    :ok
  end

  defp process_event(%{event_type: "deleted"} = event) do
    # Remove document from database
    case Zaq.Repo.get_by(Zaq.Ingestion.Document, source: "google_drive:#{event.provider_file_id}") do
      nil -> :ok
      doc -> Zaq.Repo.delete(doc)
    end
  end

  defp process_event(event) do
    watched_folder = Zaq.Repo.preload(event, :watched_folder).watched_folder
    config = Zaq.Channels.get_channel_config!(watched_folder.channel_config_id)

    # Download file
    case API.download_file(config, event.provider_file_id, event.mime_type) do
      {:ok, content} ->
        # Determine file extension for temp file
        ext = extension_for_mime(event.mime_type)
        temp_path = Path.join(System.tmp_dir!(), "#{event.provider_file_id}#{ext}")
        
        # Write to temp file
        File.write!(temp_path, content)
        
        try do
          # Process through existing ingestion pipeline
          case Ingestion.ingest_file(temp_path, :auto) do
            {:ok, job} ->
              # Update document source to include Google Drive reference
              if doc = Zaq.Repo.get(Zaq.Ingestion.Document, job.document_id) do
                metadata = Map.merge(doc.metadata || %{}, %{
                  "google_drive_file_id" => event.provider_file_id,
                  "google_drive_url" => event.metadata["web_view_link"],
                  "source_folder" => watched_folder.path
                })
                
                Zaq.Ingestion.Document.changeset(doc, %{metadata: metadata})
                |> Zaq.Repo.update()
              end
              
              :ok

            {:error, reason} ->
              {:error, reason}
          end
        after
          # Clean up temp file
          File.rm(temp_path)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extension_for_mime("application/pdf"), do: ".pdf"
  defp extension_for_mime("text/plain"), do: ".txt"
  defp extension_for_mime("text/markdown"), do: ".md"
  defp extension_for_mime("image/jpeg"), do: ".jpg"
  defp extension_for_mime("image/png"), do: ".png"
  defp extension_for_mime("application/vnd.openxmlformats-officedocument.wordprocessingml.document"), do: ".docx"
  defp extension_for_mime("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"), do: ".xlsx"
  defp extension_for_mime("application/vnd.openxmlformats-officedocument.presentationml.presentation"), do: ".pptx"
  defp extension_for_mime("application/msword"), do: ".doc"
  defp extension_for_mime("application/vnd.ms-excel"), do: ".xls"
  defp extension_for_mime("application/vnd.ms-powerpoint"), do: ".ppt"
  defp extension_for_mime(_), do: ""
end
```

**`Zaq.Channels.Ingestion.GoogleDrive.SyncWorker`**

```elixir
defmodule Zaq.Channels.Ingestion.GoogleDrive.SyncWorker do
  @moduledoc """
  Periodic sync worker for Google Drive watched folders.
  """

  use Oban.Worker,
    queue: :ingestion,
    max_attempts: 3

  require Logger

  alias Zaq.Channels.Ingestion.GoogleDrive

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"channel_config_id" => config_id}}) do
    config = Zaq.Channels.get_channel_config!(config_id)
    folders = Zaq.Ingestion.list_watched_folders(config_id)

    Enum.each(folders, fn folder ->
      if folder.active do
        Logger.info("[GoogleDrive.SyncWorker] Syncing folder: #{folder.folder_name}")
        
        case GoogleDrive.sync_folder(config, folder) do
          {:ok, count} ->
            Logger.info("[GoogleDrive.SyncWorker] Synced #{count} files from #{folder.folder_name}")
            
          {:error, reason} ->
            Logger.error("[GoogleDrive.SyncWorker] Sync failed for #{folder.folder_name}: #{inspect(reason)}")
        end
      end
    end)

    # Reschedule for next sync (every 15 minutes)
    %{channel_config_id: config_id}
    |> __MODULE__.new(schedule_in: 15 * 60)
    |> Oban.insert()

    :ok
  end
end
```

---

## Phase 3: UI Components

### 3.1 LiveView: Google Drive Configuration

**`ZaqWeb.Live.BO.GoogleDriveConfigLive`**

```elixir
defmodule ZaqWeb.Live.BO.GoogleDriveConfigLive do
  use ZaqWeb, :live_view

  import ZaqWeb.CoreComponents

  alias Zaq.Channels
  alias Zaq.Channels.Ingestion.GoogleDrive
  alias Zaq.Channels.Ingestion.GoogleDrive.API

  @impl true
  def mount(_params, _session, socket) do
    config = Channels.get_channel_config_by_provider("google_drive") || %Channels.ChannelConfig{}
    
    {:ok, 
     socket
     |> assign(:page_title, "Google Drive Configuration")
     |> assign(:config, config)
     |> assign(:changeset, Channels.change_channel_config(config))
     |> assign(:connection_status, nil)
     |> assign(:folders, [])
     |> assign(:selected_folder, nil)
     |> assign(:watched_folders, [])
     |> assign(:show_folder_picker, false)
     |> assign(:oauth_url, generate_oauth_url())}
  end

  @impl true
  def handle_event("validate", %{"config" => params}, socket) do
    changeset = 
      socket.assigns.config
      |> Channels.change_channel_config(params)
      |> Map.put(:action, :validate)
    
    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"config" => params}, socket) do
    params = 
      params
      |> Map.put("provider", "google_drive")
      |> Map.put("kind", "ingestion")
      |> Map.put("enabled", true)

    case socket.assigns.config.id do
      nil -> 
        case Channels.create_channel_config(params) do
          {:ok, config} ->
            {:noreply, 
             socket
             |> assign(:config, config)
             |> put_flash(:info, "Configuration saved successfully")
             |> push_navigate(to: ~p"/bo/channels/ingestion/google_drive")}

          {:error, changeset} ->
            {:noreply, assign(socket, :changeset, changeset)}
        end

      id ->
        config = Channels.get_channel_config!(id)
        
        case Channels.update_channel_config(config, params) do
          {:ok, config} ->
            {:noreply, 
             socket
             |> assign(:config, config)
             |> put_flash(:info, "Configuration updated successfully")}

          {:error, changeset} ->
            {:noreply, assign(socket, :changeset, changeset)}
        end
    end
  end

  def handle_event("test_connection", _params, socket) do
    config = socket.assigns.config
    
    case GoogleDrive.connect(config) do
      {:ok, _state} ->
        {:noreply, 
         socket
         |> assign(:connection_status, :connected)
         |> put_flash(:info, "Successfully connected to Google Drive")}

      {:error, reason} ->
        {:noreply, 
         socket
         |> assign(:connection_status, :failed)
         |> put_flash(:error, "Connection failed: #{inspect(reason)}")}
    end
  end

  def handle_event("open_folder_picker", _params, socket) do
    config = socket.assigns.config
    
    case API.list_folders(config, "root") do
      {:ok, folders} ->
        {:noreply, 
         socket
         |> assign(:folders, folders)
         |> assign(:show_folder_picker, true)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to load folders")}
    end
  end

  def handle_event("select_folder", %{"folder_id" => folder_id}, socket) do
    config = socket.assigns.config
    
    case API.get_file(config, folder_id) do
      {:ok, file} ->
        {:ok, path} = API.get_folder_path(config, folder_id)
        
        selected = %{
          id: folder_id,
          name: file["name"],
          path: path
        }
        
        {:noreply, assign(socket, :selected_folder, selected)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to get folder details")}
    end
  end

  def handle_event("add_watched_folder", _params, socket) do
    config = socket.assigns.config
    selected = socket.assigns.selected_folder
    
    webhook_url = ZaqWeb.Endpoint.url() <> "/webhooks/google_drive"
    
    case GoogleDrive.add_watched_folder(config, selected.id, 
           include_subfolders: true,
           webhook_url: webhook_url) do
      {:ok, folder} ->
        watched_folders = Zaq.Ingestion.list_watched_folders(config.id)
        
        {:noreply, 
         socket
         |> assign(:watched_folders, watched_folders)
         |> assign(:selected_folder, nil)
         |> assign(:show_folder_picker, false)
         |> put_flash(:info, "Folder '#{selected.name}' is now being watched")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to add folder: #{inspect(reason)}")}
    end
  end

  def handle_event("remove_watched_folder", %{"folder_id" => folder_id}, socket) do
    config = socket.assigns.config
    folder = Zaq.Ingestion.get_watched_folder!(folder_id)
    
    case GoogleDrive.remove_watched_folder(config, folder) do
      {:ok, _} ->
        watched_folders = Zaq.Ingestion.list_watched_folders(config.id)
        {:noreply, 
         socket
         |> assign(:watched_folders, watched_folders)
         |> put_flash(:info, "Folder removed from watch list")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to remove folder: #{inspect(reason)}")}
    end
  end

  def handle_event("sync_folder", %{"folder_id" => folder_id}, socket) do
    config = socket.assigns.config
    folder = Zaq.Ingestion.get_watched_folder!(folder_id)
    
    # Trigger sync asynchronously
    Task.start(fn ->
      GoogleDrive.sync_folder(config, folder)
    end)
    
    {:noreply, put_flash(socket, :info, "Sync started for '#{folder.folder_name}'")}
  end

  def handle_event("close_folder_picker", _params, socket) do
    {:noreply, assign(socket, :show_folder_picker, false)}
  end

  defp generate_oauth_url do
    client_id = System.get_env("GOOGLE_CLIENT_ID")
    redirect_uri = ZaqWeb.Endpoint.url() <> "/auth/google/callback"
    scope = "https://www.googleapis.com/auth/drive.readonly"
    
    "https://accounts.google.com/o/oauth2/v2/auth?" <> URI.encode_query(%{
      client_id: client_id,
      redirect_uri: redirect_uri,
      response_type: "code",
      scope: scope,
      access_type: "offline",
      prompt: "consent"
    })
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="mb-8">
          <h1 class="text-3xl font-bold text-gray-900">Google Drive Configuration</h1>
          <p class="mt-2 text-gray-600">Connect and configure Google Drive as an ingestion source</p>
        </div>

        <%!-- OAuth Connection Section --%>
        <div class="bg-white shadow rounded-lg p-6 mb-6">
          <h2 class="text-lg font-medium text-gray-900 mb-4">1. Connect to Google Drive</h2>
          
          <%= if @config.id do %>
            <div class="flex items-center gap-4">
              <div class="flex-1">
                <div class="flex items-center gap-2">
                  <.icon name="hero-check-circle" class="w-5 h-5 text-green-500" />
                  <span class="text-green-700 font-medium">Connected</span>
                </div>
                <p class="text-sm text-gray-500 mt-1">Account is authorized and ready</p>
              </div>
              
              <button
                type="button"
                phx-click="test_connection"
                class="inline-flex items-center px-4 py-2 border border-gray-300 shadow-sm text-sm font-medium rounded-md text-gray-700 bg-white hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
              >
                <.icon name="hero-arrow-path" class="w-4 h-4 mr-2" />
                Test Connection
              </button>
            </div>
          <% else %>
            <div class="flex items-center gap-4">
              <div class="flex-1">
                <p class="text-gray-600">Authorize access to your Google Drive account</p>
              </div>
              
              <a
                href={@oauth_url}
                class="inline-flex items-center px-4 py-2 border border-transparent shadow-sm text-sm font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
              >
                <.icon name="hero-link" class="w-4 h-4 mr-2" />
                Connect Google Drive
              </a>
            </div>
          <% end %>
        </div>

        <%!-- Watched Folders Section --%>
        <%= if @config.id do %>
          <div class="bg-white shadow rounded-lg p-6 mb-6">
            <div class="flex items-center justify-between mb-4">
              <h2 class="text-lg font-medium text-gray-900">2. Select Folders to Watch</h2>
              
              <button
                type="button"
                phx-click="open_folder_picker"
                class="inline-flex items-center px-4 py-2 border border-transparent shadow-sm text-sm font-medium rounded-md text-white bg-indigo-600 hover:bg-indigo-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-indigo-500"
              >
                <.icon name="hero-plus" class="w-4 h-4 mr-2" />
                Add Folder
              </button>
            </div>

            <%= if @watched_folders == [] do %>
              <div class="text-center py-12 bg-gray-50 rounded-lg border-2 border-dashed border-gray-300">
                <.icon name="hero-folder-open" class="w-12 h-12 text-gray-400 mx-auto mb-4" />
                <p class="text-gray-500">No folders are being watched yet</p>
                <p class="text-sm text-gray-400 mt-1">Click "Add Folder" to select folders from your Drive</p>
              </div>
            <% else %>
              <div class="space-y-3">
                <%= for folder <- @watched_folders do %>
                  <div class="flex items-center justify-between p-4 bg-gray-50 rounded-lg">
                    <div class="flex items-center gap-3">
                      <.icon name="hero-folder" class="w-5 h-5 text-yellow-500" />
                      <div>
                        <p class="font-medium text-gray-900"><%= folder.folder_name %></p>
                        <p class="text-sm text-gray-500"><%= folder.path %></p>
                        <%= if folder.last_synced_at do %>
                          <p class="text-xs text-gray-400 mt-1">
                            Last synced: <%= Calendar.strftime(folder.last_synced_at, "%Y-%m-%d %H:%M") %>
                          </p>
                        <% end %>
                      </div>
                    </div>
                    
                    <div class="flex items-center gap-2">
                      <button
                        type="button"
                        phx-click="sync_folder"
                        phx-value-folder_id={folder.id}
                        class="inline-flex items-center p-2 text-gray-400 hover:text-indigo-600 transition-colors"
                        title="Sync now"
                      >
                        <.icon name="hero-arrow-path" class="w-5 h-5" />
                      </button>
                      
                      <button
                        type="button"
                        phx-click="remove_watched_folder"
                        phx-value-folder_id={folder.id}
                        class="inline-flex items-center p-2 text-gray-400 hover:text-red-600 transition-colors"
                        title="Remove"
                      >
                        <.icon name="hero-trash" class="w-5 h-5" />
                      </button>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- File Type Filter --%>
          <div class="bg-white shadow rounded-lg p-6">
            <h2 class="text-lg font-medium text-gray-900 mb-4">3. File Type Support</h2>
            
            <div class="grid grid-cols-2 md:grid-cols-3 gap-4">
              <div class="flex items-center gap-2">
                <.icon name="hero-document-text" class="w-5 h-5 text-blue-500" />
                <span class="text-sm text-gray-700">PDF Documents</span>
              </div>
              <div class="flex items-center gap-2">
                <.icon name="hero-document" class="w-5 h-5 text-blue-600" />
                <span class="text-sm text-gray-700">Word (DOC, DOCX)</span>
              </div>
              <div class="flex items-center gap-2">
                <.icon name="hero-table-cells" class="w-5 h-5 text-green-600" />
                <span class="text-sm text-gray-700">Excel (XLS, XLSX)</span>
              </div>
              <div class="flex items-center gap-2">
                <.icon name="hero-presentation-chart-bar" class="w-5 h-5 text-orange-600" />
                <span class="text-sm text-gray-700">PowerPoint (PPT, PPTX)</span>
              </div>
              <div class="flex items-center gap-2">
                <.icon name="hero-photo" class="w-5 h-5 text-purple-500" />
                <span class="text-sm text-gray-700">Images (JPG, PNG, GIF)</span>
              </div>
              <div class="flex items-center gap-2">
                <.icon name="hero-document-text" class="w-5 h-5 text-gray-600" />
                <span class="text-sm text-gray-700">Text & Markdown</span>
              </div>
            </div>
            
            <div class="mt-4 p-3 bg-blue-50 rounded-lg">
              <p class="text-sm text-blue-700">
                <.icon name="hero-information-circle" class="w-4 h-4 inline mr-1" />
                Google Workspace files (Docs, Sheets, Slides) are automatically exported to their Office equivalents
              </p>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Folder Picker Modal --%>
      <%= if @show_folder_picker do %>
        <div class="fixed inset-0 z-50 overflow-y-auto" aria-labelledby="modal-title" role="dialog" aria-modal="true">
          <div class="flex items-end justify-center min-h-screen pt-4 px-4 pb-20 text-center sm:block sm:p-0">
            <div class="fixed inset-0 bg-gray-500 bg-opacity-75 transition-opacity" aria-hidden="true" phx-click="close_folder_picker"></div>
            <span class="hidden sm:inline-block sm:align-middle sm:h-screen" aria-hidden="true">&#8203;</span>
            
            <div class="inline-block align-bottom bg-white rounded-lg text-left overflow-hidden shadow-xl transform transition-all sm:my-8 sm:align-middle sm:max-w-lg sm:w-full">
              <div class="bg-white px-4 pt-5 pb-4 sm:p-6 sm:pb-4">
                <h3 class="text-lg font-medium text-gray-900 mb-4" id="modal-title">Select Folder</h3>
                
                <div class="max-h-96 overflow-y-auto">
                  <%= if @folders == [] do %>
                    <p class="text-gray-500 text-center py-8">No folders found</p>
                  <% else %>
                    <div class="space-y-2">
                      <%= for folder <- @folders do %>
                        <button
                          type="button"
                          phx-click="select_folder"
                          phx-value-folder_id={folder["id"]}
                          class={[
                            "w-full flex items-center gap-3 p-3 rounded-lg text-left transition-colors",
                            @selected_folder && @selected_folder.id == folder["id"] && "bg-indigo-50 border-indigo-500",
                            (!@selected_folder || @selected_folder.id != folder["id"]) && "hover:bg-gray-50 border-transparent"
                          ]}
                          style={if @selected_folder && @selected_folder.id == folder["id"], do: "border: 1px solid #6366f1;", else: "border: 1px solid transparent;"}
                        >
                          <.icon name="hero-folder" class="w-5 h-5 text-yellow-500" />
                          <span class="text-gray-900"><%= folder["name"] %></span>
                        </button>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
              
              <div class="bg-gray-50 px-4 py-3 sm:px-6 sm:flex sm:flex-row-reverse">
                <button
                  type="button"
                  phx-click="add_watched_folder"
                  disabled={!@selected_folder}
                  class={[
                    "w-full inline-flex justify-center rounded-md border border-transparent shadow-sm px-4 py-2 text-base font-medium text-white sm:ml-3 sm:w-auto sm:text-sm",
                    if(@selected_folder, do: "bg-indigo-600 hover:bg-indigo-700", else: "bg-gray-300 cursor-not-allowed")
                  ]}
                >
                  Add Folder
                </button>
                <button
                  type="button"
                  phx-click="close_folder_picker"
                  class="mt-3 w-full inline-flex justify-center rounded-md border border-gray-300 shadow-sm px-4 py-2 bg-white text-base font-medium text-gray-700 hover:bg-gray-50 sm:mt-0 sm:ml-3 sm:w-auto sm:text-sm"
                >
                  Cancel
                </button>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
```

### 3.2 LiveView: Ingestion Events Monitor

**`ZaqWeb.Live.BO.IngestionEventsLive`**

```elixir
defmodule ZaqWeb.Live.BO.IngestionEventsLive do
  use ZaqWeb, :live_view

  import ZaqWeb.CoreComponents

  alias Zaq.Ingestion

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Ingestion.subscribe()
      :timer.send_interval(5000, self(), :refresh_events)
    end

    {:ok, 
     socket
     |> assign(:page_title, "Ingestion Events")
     |> assign(:events, load_events())
     |> assign(:stats, load_stats())
     |> assign(:filter, "all")
     |> assign(:selected_event, nil)}
  end

  @impl true
  def handle_info(:refresh_events, socket) do
    {:noreply, 
     socket
     |> assign(:events, load_events(socket.assigns.filter))
     |> assign(:stats, load_stats())}
  end

  def handle_info({:job_updated, _job}, socket) do
    {:noreply, 
     socket
     |> assign(:events, load_events(socket.assigns.filter))
     |> assign(:stats, load_stats())}
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply, 
     socket
     |> assign(:filter, status)
     |> assign(:events, load_events(status))}
  end

  def handle_event("view_details", %{"event_id" => event_id}, socket) do
    event = 
      IngestionEvent
      |> Zaq.Repo.get!(event_id)
      |> Zaq.Repo.preload(:watched_folder)
    
    {:noreply, assign(socket, :selected_event, event)}
  end

  def handle_event("close_details", _params, socket) do
    {:noreply, assign(socket, :selected_event, nil)}
  end

  def handle_event("retry_event", %{"event_id" => event_id}, socket) do
    IngestionEvent
    |> Zaq.Repo.get!(event_id)
    |> IngestionEvent.changeset(%{status: "pending", error_message: nil})
    |> Zaq.Repo.update()
    
    # Trigger processing
    %{}
    |> Zaq.Channels.Ingestion.GoogleDrive.EventWorker.new()
    |> Oban.insert()
    
    {:noreply, 
     socket
     |> assign(:events, load_events(socket.assigns.filter))
     |> put_flash(:info, "Event queued for retry")}
  end

  defp load_events(filter \\ "all") do
    query = IngestionEvent
    |> order_by(desc: :inserted_at)
    |> limit(100)
    |> Zaq.Repo.preload(watched_folder: :channel_config)

    query = 
      case filter do
        "all" -> query
        status -> where(query, [e], e.status == ^status)
      end

    Zaq.Repo.all(query)
  end

  defp load_stats do
    total = Zaq.Repo.aggregate(IngestionEvent, :count, :id)
    pending = IngestionEvent |> where([e], e.status == "pending") |> Zaq.Repo.aggregate(:count, :id)
    processing = IngestionEvent |> where([e], e.status == "processing") |> Zaq.Repo.aggregate(:count, :id)
    completed = IngestionEvent |> where([e], e.status == "completed") |> Zaq.Repo.aggregate(:count, :id)
    failed = IngestionEvent |> where([e], e.status == "failed") |> Zaq.Repo.aggregate(:count, :id)

    %{total: total, pending: pending, processing: processing, completed: completed, failed: failed}
  end

  defp status_color("pending"), do: "bg-yellow-100 text-yellow-800"
  defp status_color("processing"), do: "bg-blue-100 text-blue-800"
  defp status_color("completed"), do: "bg-green-100 text-green-800"
  defp status_color("failed"), do: "bg-red-100 text-red-800"
  defp status_color(_), do: "bg-gray-100 text-gray-800"

  defp event_type_icon("created"), do: "hero-document-plus"
  defp event_type_icon("modified"), do: "hero-pencil-square"
  defp event_type_icon("deleted"), do: "hero-trash"
  defp event_type_icon(_), do: "hero-document"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div class="mb-8">
          <h1 class="text-3xl font-bold text-gray-900">Ingestion Events</h1>
          <p class="mt-2 text-gray-600">Monitor file changes and ingestion status from all connected sources</p>
        </div>

        <%!-- Stats Cards --%>
        <div class="grid grid-cols-2 md:grid-cols-5 gap-4 mb-6">
          <div class="bg-white shadow rounded-lg p-4">
            <p class="text-sm text-gray-500">Total</p>
            <p class="text-2xl font-bold text-gray-900"><%= @stats.total %></p>
          </div>
          <div class="bg-white shadow rounded-lg p-4">
            <p class="text-sm text-yellow-600">Pending</p>
            <p class="text-2xl font-bold text-yellow-700"><%= @stats.pending %></p>
          </div>
          <div class="bg-white shadow rounded-lg p-4">
            <p class="text-sm text-blue-600">Processing</p>
            <p class="text-2xl font-bold text-blue-700"><%= @stats.processing %></p>
          </div>
          <div class="bg-white shadow rounded-lg p-4">
            <p class="text-sm text-green-600">Completed</p>
            <p class="text-2xl font-bold text-green-700"><%= @stats.completed %></p>
          </div>
          <div class="bg-white shadow rounded-lg p-4">
            <p class="text-sm text-red-600">Failed</p>
            <p class="text-2xl font-bold text-red-700"><%= @stats.failed %></p>
          </div>
        </div>

        <%!-- Filter Tabs --%>
        <div class="bg-white shadow rounded-lg mb-6">
          <div class="border-b border-gray-200">
            <nav class="-mb-px flex">
              <%= for {label, value} <- [{"All", "all"}, {"Pending", "pending"}, {"Processing", "processing"}, {"Completed", "completed"}, {"Failed", "failed"}] do %>
                <button
                  phx-click="filter"
                  phx-value-status={value}
                  class={[
                    "w-1/5 py-4 px-1 text-center border-b-2 font-medium text-sm",
                    @filter == value && "border-indigo-500 text-indigo-600",
                    @filter != value && "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"
                  ]}
                >
                  <%= label %>
                </button>
              <% end %>
            </nav>
          </div>

          <%!-- Events Table --%>
          <div class="overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Event</th>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">File</th>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Source</th>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Status</th>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Time</th>
                  <th class="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">Actions</th>
                </tr>
              </thead>
              <tbody class="bg-white divide-y divide-gray-200">
                <%= for event <- @events do %>
                  <tr class="hover:bg-gray-50">
                    <td class="px-6 py-4 whitespace-nowrap">
                      <div class="flex items-center">
                        <.icon name={event_type_icon(event.event_type)} class="w-5 h-5 text-gray-400 mr-2" />
                        <span class="text-sm text-gray-900 capitalize"><%= event.event_type %></span>
                      </div>
                    </td>
                    <td class="px-6 py-4">
                      <div class="text-sm font-medium text-gray-900"><%= event.file_name %></div>
                      <div class="text-sm text-gray-500"><%= event.mime_type %></div>
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap">
                      <%= if event.watched_folder do %>
                        <div class="text-sm text-gray-900"><%= event.watched_folder.folder_name %></div>
                        <div class="text-sm text-gray-500"><%= event.watched_folder.channel_config.provider %></div>
                      <% else %>
                        <span class="text-sm text-gray-500">Unknown</span>
                      <% end %>
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap">
                      <span class={["px-2 inline-flex text-xs leading-5 font-semibold rounded-full", status_color(event.status)]}>
                        <%= event.status %>
                      </span>
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                      <%= Calendar.strftime(event.inserted_at, "%Y-%m-%d %H:%M:%S") %>
                    </td>
                    <td class="px-6 py-4 whitespace-nowrap text-right text-sm font-medium">
                      <button
                        phx-click="view_details"
                        phx-value-event_id={event.id}
                        class="text-indigo-600 hover:text-indigo-900 mr-3"
                      >
                        Details
                      </button>
                      <%= if event.status == "failed" do %>
                        <button
                          phx-click="retry_event"
                          phx-value-event_id={event.id}
                          class="text-green-600 hover:text-green-900"
                        >
                          Retry
                        </button>
                      <% end %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <%!-- Event Details Modal --%>
      <%= if @selected_event do %>
        <div class="fixed inset-0 z-50 overflow-y-auto" aria-labelledby="modal-title" role="dialog" aria-modal="true">
          <div class="flex items-end justify-center min-h-screen pt-4 px-4 pb-20 text-center sm:block sm:p-0">
            <div class="fixed inset-0 bg-gray-500 bg-opacity-75 transition-opacity" aria-hidden="true" phx-click="close_details"></div>
            <span class="hidden sm:inline-block sm:align-middle sm:h-screen" aria-hidden="true">&#8203;</span>
            
            <div class="inline-block align-bottom bg-white rounded-lg text-left overflow-hidden shadow-xl transform transition-all sm:my-8 sm:align-middle sm:max-w-2xl sm:w-full">
              <div class="bg-white px-4 pt-5 pb-4 sm:p-6">
                <h3 class="text-lg font-medium text-gray-900 mb-4">Event Details</h3>
                
                <div class="space-y-4">
                  <div class="grid grid-cols-2 gap-4">
                    <div>
                      <label class="block text-sm font-medium text-gray-500">Event Type</label>
                      <p class="text-sm text-gray-900 capitalize"><%= @selected_event.event_type %></p>
                    </div>
                    <div>
                      <label class="block text-sm font-medium text-gray-500">Status</label>
                      <span class={["px-2 inline-flex text-xs leading-5 font-semibold rounded-full", status_color(@selected_event.status)]}>
                        <%= @selected_event.status %>
                      </span>
                    </div>
                  </div>
                  
                  <div>
                    <label class="block text-sm font-medium text-gray-500">File Name</label>
                    <p class="text-sm text-gray-900"><%= @selected_event.file_name %></p>
                  </div>
                  
                  <div>
                    <label class="block text-sm font-medium text-gray-500">MIME Type</label>
                    <p class="text-sm text-gray-900"><%= @selected_event.mime_type %></p>
                  </div>
                  
                  <%= if @selected_event.watched_folder do %>
                    <div>
                      <label class="block text-sm font-medium text-gray-500">Source Folder</label>
                      <p class="text-sm text-gray-900"><%= @selected_event.watched_folder.path %></p>
                    </div>
                  <% end %>
                  
                  <%= if @selected_event.error_message do %>
                    <div class="bg-red-50 p-3 rounded-lg">
                      <label class="block text-sm font-medium text-red-700">Error</label>
                      <p class="text-sm text-red-600 mt-1"><%= @selected_event.error_message %></p>
                    </div>
                  <% end %>
                  
                  <%= if @selected_event.metadata != %{} do %>
                    <div>
                      <label class="block text-sm font-medium text-gray-500">Metadata</label>
                      <pre class="mt-1 text-xs text-gray-700 bg-gray-100 p-2 rounded overflow-x-auto"><%= Jason.encode!(@selected_event.metadata, pretty: true) %></pre>
                    </div>
                  <% end %>
                </div>
              </div>
              
              <div class="bg-gray-50 px-4 py-3 sm:px-6 sm:flex sm:flex-row-reverse">
                <%= if @selected_event.status == "failed" do %>
                  <button
                    type="button"
                    phx-click="retry_event"
                    phx-value-event_id={@selected_event.id}
                    phx-click-away="close_details"
                    class="w-full inline-flex justify-center rounded-md border border-transparent shadow-sm px-4 py-2 bg-green-600 text-base font-medium text-white hover:bg-green-700 sm:ml-3 sm:w-auto sm:text-sm"
                  >
                    Retry
                  </button>
                <% end %>
                <button
                  type="button"
                  phx-click="close_details"
                  class="mt-3 w-full inline-flex justify-center rounded-md border border-gray-300 shadow-sm px-4 py-2 bg-white text-base font-medium text-gray-700 hover:bg-gray-50 sm:mt-0 sm:ml-3 sm:w-auto sm:text-sm"
                >
                  Close
                </button>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end
end
```

### 3.3 OAuth Callback Controller

**`ZaqWeb.Controllers.GoogleAuthController`**

```elixir
defmodule ZaqWeb.Controllers.GoogleAuthController do
  use ZaqWeb, :controller

  require Logger

  alias Zaq.Channels

  def callback(conn, %{"code" => code}) do
    # Exchange code for tokens
    case exchange_code_for_tokens(code) do
      {:ok, tokens} ->
        # Get or create Google Drive channel config
        config = 
          case Channels.get_channel_config_by_provider("google_drive") do
            nil -> 
              {:ok, new_config} = Channels.create_channel_config(%{
                provider: "google_drive",
                kind: "ingestion",
                enabled: true,
                client_id: System.get_env("GOOGLE_CLIENT_ID"),
                client_secret: System.get_env("GOOGLE_CLIENT_SECRET"),
                refresh_token: tokens["refresh_token"],
                access_token: tokens["access_token"],
                token_expires_at: DateTime.utc_now() |> DateTime.add(tokens["expires_in"], :second)
              })
              new_config

            existing ->
              {:ok, updated} = Channels.update_channel_config(existing, %{
                refresh_token: tokens["refresh_token"] || existing.refresh_token,
                access_token: tokens["access_token"],
                token_expires_at: DateTime.utc_now() |> DateTime.add(tokens["expires_in"], :second)
              })
              updated
          end

        conn
        |> put_flash(:info, "Google Drive connected successfully!")
        |> redirect(to: ~p"/bo/channels/ingestion/google_drive")

      {:error, reason} ->
        Logger.error("[GoogleAuthController] OAuth failed: #{inspect(reason)}")
        
        conn
        |> put_flash(:error, "Failed to connect Google Drive. Please try again.")
        |> redirect(to: ~p"/bo/channels/ingestion/google_drive")
    end
  end

  def callback(conn, %{"error" => error}) do
    Logger.error("[GoogleAuthController] OAuth error: #{error}")
    
    conn
    |> put_flash(:error, "Authorization denied or failed.")
    |> redirect(to: ~p"/bo/channels/ingestion/google_drive")
  end

  defp exchange_code_for_tokens(code) do
    client_id = System.get_env("GOOGLE_CLIENT_ID")
    client_secret = System.get_env("GOOGLE_CLIENT_SECRET")
    redirect_uri = ZaqWeb.Endpoint.url() <> "/auth/google/callback"

    body = %{
      code: code,
      client_id: client_id,
      client_secret: client_secret,
      redirect_uri: redirect_uri,
      grant_type: "authorization_code"
    }

    case Req.post(
           url: "https://oauth2.googleapis.com/token",
           form: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("[GoogleAuthController] Token exchange failed: #{status} - #{inspect(body)}")
        {:error, :token_exchange_failed}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

### 3.4 Webhook Controller

**`ZaqWeb.Controllers.GoogleDriveWebhookController`**

```elixir
defmodule ZaqWeb.Controllers.GoogleDriveWebhookController do
  use ZaqWeb, :controller

  require Logger

  alias Zaq.Channels.Ingestion.GoogleDrive

  def handle(conn, params) do
    # Verify webhook signature if needed
    # Google Drive webhooks include a X-Goog-Channel-ID header
    channel_id = get_req_header(conn, "x-goog-channel-id") |> List.first()
    resource_id = get_req_header(conn, "x-goog-resource-id") |> List.first()
    resource_state = get_req_header(conn, "x-goog-resource-state") |> List.first()

    Logger.info("[GoogleDriveWebhook] Received webhook - channel: #{channel_id}, state: #{resource_state}")

    # Find the watched folder by channel ID
    case Zaq.Repo.get_by(Zaq.Ingestion.WatchedFolder, watch_channel_id: channel_id) do
      nil ->
        Logger.warning("[GoogleDriveWebhook] Unknown channel ID: #{channel_id}")
        send_resp(conn, 404, "Not found")

      folder ->
        # Trigger sync for this folder
        config = Zaq.Channels.get_channel_config!(folder.channel_config_id)
        
        # Handle the change notification
        GoogleDrive.handle_event(%{
          "kind" => "drive#change",
          "fileId" => resource_id,
          "changeType" => "file"
        }, %{config: config, watched_folders: [folder]})

        send_resp(conn, 200, "OK")
    end
  end
end
```

---

## Phase 4: Routes & Configuration

### 4.1 Router Updates

```elixir
# lib/zaq_web/router.ex

defmodule ZaqWeb.Router do
  use ZaqWeb, :router

  # ... existing routes ...

  scope "/bo", ZaqWeb.Live.BO do
    pipe_through [:browser, :require_authenticated_user]

    # ... existing routes ...

    # Google Drive specific routes
    live "/channels/ingestion/google_drive", GoogleDriveConfigLive, :index
    live "/ingestion/events", IngestionEventsLive, :index
  end

  # OAuth callback
  scope "/auth", ZaqWeb.Controllers do
    pipe_through :browser

    get "/google/callback", GoogleAuthController, :callback
  end

  # Webhooks
  scope "/webhooks", ZaqWeb.Controllers do
    post "/google_drive", GoogleDriveWebhookController, :handle
  end
end
```

### 4.2 Environment Configuration

```elixir
# config/runtime.exs

# Google Drive OAuth credentials
config :zaq, :google_drive,
  client_id: System.get_env("GOOGLE_CLIENT_ID"),
  client_secret: System.get_env("GOOGLE_CLIENT_SECRET"),
  webhook_secret: System.get_env("GOOGLE_WEBHOOK_SECRET")
```

---

## Phase 5: Testing Strategy

### 5.1 Mocks Definition

```elixir
# test/support/mocks.ex

Mox.defmock(Zaq.Channels.Ingestion.GoogleDrive.APIMock, for: Zaq.Channels.Ingestion.GoogleDrive.API.Behaviour)
```

### 5.2 API Behaviour

```elixir
# lib/zaq/channels/ingestion/google_drive/api/behaviour.ex

defmodule Zaq.Channels.Ingestion.GoogleDrive.API.Behaviour do
  @callback refresh_access_token(map()) :: {:ok, map()} | {:error, term()}
  @callback list_files(map(), String.t(), keyword()) :: {:ok, list()} | {:error, term()}
  @callback get_file(map(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback download_file(map(), String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  @callback create_watch_channel(map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback stop_watch_channel(map(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback list_folders(map(), String.t()) :: {:ok, list()} | {:error, term()}
  @callback get_folder_path(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback supported_mime_types() :: list(String.t())
end
```

### 5.3 Test Examples

```elixir
# test/zaq/channels/ingestion/google_drive_test.exs

defmodule Zaq.Channels.Ingestion.GoogleDriveTest do
  use Zaq.DataCase

  import Mox

  alias Zaq.Channels.Ingestion.GoogleDrive
  alias Zaq.Channels.Ingestion.GoogleDrive.APIMock

  setup :verify_on_exit!

  describe "connect/1" do
    test "returns ok with valid credentials" do
      config = %Zaq.Channels.ChannelConfig{
        id: "test-id",
        refresh_token: "valid_token",
        client_id: "client_id",
        client_secret: "client_secret"
      }

      expect(APIMock, :list_folders, fn ^config, "root" ->
        {:ok, [%{"id" => "folder1", "name" => "Test Folder"}]}
      end)

      assert {:ok, state} = GoogleDrive.connect(config)
      assert state.connected == true
    end

    test "returns error with missing credentials" do
      config = %Zaq.Channels.ChannelConfig{
        id: "test-id",
        refresh_token: nil,
        client_id: "client_id",
        client_secret: "client_secret"
      }

      assert {:error, :missing_credentials} = GoogleDrive.connect(config)
    end
  end

  describe "add_watched_folder/3" do
    test "creates watched folder with watch channel" do
      config = insert(:channel_config, provider: "google_drive")
      folder_id = "drive_folder_123"
      webhook_url = "https://example.com/webhook"

      expect(APIMock, :get_file, fn ^config, ^folder_id ->
        {:ok, %{"id" => folder_id, "name" => "Test Folder", "mimeType" => "application/vnd.google-apps.folder"}}
      end)

      expect(APIMock, :get_folder_path, fn ^config, ^folder_id ->
        {:ok, "My Drive / Test Folder"}
      end)

      expect(APIMock, :create_watch_channel, fn ^config, ^folder_id, ^webhook_url ->
        {:ok, %{channel_id: "channel_123", expiration: DateTime.utc_now()}}
      end)

      assert {:ok, folder} = GoogleDrive.add_watched_folder(config, folder_id, webhook_url: webhook_url)
      assert folder.folder_name == "Test Folder"
      assert folder.watch_channel_id == "channel_123"
    end
  end
end
```

---

## Phase 6: Deployment & Operations

### 6.1 Migration Script

```bash
#!/bin/bash
# scripts/setup_google_drive.sh

echo "Setting up Google Drive ingestion channel..."

# Run migrations
echo "Running database migrations..."
mix ecto.migrate

# Verify environment variables
if [ -z "$GOOGLE_CLIENT_ID" ]; then
  echo "ERROR: GOOGLE_CLIENT_ID is not set"
  exit 1
fi

if [ -z "$GOOGLE_CLIENT_SECRET" ]; then
  echo "ERROR: GOOGLE_CLIENT_SECRET is not set"
  exit 1
fi

echo "Setup complete!"
echo ""
echo "Next steps:"
echo "1. Configure OAuth consent screen in Google Cloud Console"
echo "2. Add authorized redirect URI: https://your-domain.com/auth/google/callback"
echo "3. Add authorized webhook domain: https://your-domain.com"
echo "4. Visit /bo/channels/ingestion/google_drive to connect"
```

### 6.2 Monitoring & Alerting

```elixir
# Add to application.ex or a dedicated monitoring module

defmodule Zaq.Ingestion.Monitoring do
  @moduledoc """
  Monitoring and alerting for ingestion channels.
  """

  require Logger

  def check_google_drive_health do
    config = Zaq.Channels.get_channel_config_by_provider("google_drive")
    
    if config do
      case Zaq.Channels.Ingestion.GoogleDrive.connect(config) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.error("[Monitoring] Google Drive connection failed: #{inspect(reason)}")
          # Send alert to monitoring system
          :error
      end
    end
  end

  def pending_events_count do
    Zaq.Ingestion.IngestionEvent
    |> where([e], e.status == "pending")
    |> Zaq.Repo.aggregate(:count, :id)
  end

  def failed_events_count(since_hours \\ 24) do
    since = DateTime.utc_now() |> DateTime.add(-since_hours, :hour)
    
    Zaq.Ingestion.IngestionEvent
    |> where([e], e.status == "failed" and e.inserted_at > ^since)
    |> Zaq.Repo.aggregate(:count, :id)
  end
end
```

---

## Implementation Checklist

### Database & Schema
- [ ] Create migration for `ingestion_watched_folders` table
- [ ] Create migration for `ingestion_events` table
- [ ] Add OAuth fields to `channel_configs` table
- [ ] Create `WatchedFolder` schema
- [ ] Create `IngestionEvent` schema
- [ ] Extend `Zaq.Ingestion` context with new functions

### Google Drive Integration
- [ ] Implement `GoogleDrive.API` module with all API functions
- [ ] Implement `IngestionChannel` behaviour in `GoogleDrive` module
- [ ] Create `EventWorker` for processing file changes
- [ ] Create `SyncWorker` for periodic sync
- [ ] Add OAuth token refresh logic

### UI Components
- [ ] Create `GoogleDriveConfigLive` for configuration
- [ ] Create folder picker modal component
- [ ] Create `IngestionEventsLive` for monitoring
- [ ] Add event details modal
- [ ] Add status badges and filtering

### Authentication & Webhooks
- [ ] Create `GoogleAuthController` for OAuth callback
- [ ] Create `GoogleDriveWebhookController` for push notifications
- [ ] Implement webhook signature verification
- [ ] Add webhook URL configuration

### Testing
- [ ] Define API behaviour for mocking
- [ ] Write unit tests for `GoogleDrive` module
- [ ] Write tests for API client
- [ ] Write LiveView tests
- [ ] Add integration tests for OAuth flow

### Documentation
- [ ] Add setup instructions to README
- [ ] Document environment variables
- [ ] Create user guide for UI
- [ ] Document API rate limits and quotas

### Deployment
- [ ] Create migration script
- [ ] Add monitoring and alerting
- [ ] Configure production OAuth credentials
- [ ] Set up webhook endpoints
- [ ] Configure Oban queues

---

## File Structure Summary

```
lib/
├── zaq/
│   ├── channels/
│   │   └── ingestion/
│   │       ├── google_drive.ex
│   │       └── google_drive/
│   │           ├── api.ex
│   │           ├── api/
│   │           │   └── behaviour.ex
│   │           ├── event_worker.ex
│   │           └── sync_worker.ex
│   └── ingestion/
│       ├── watched_folder.ex
│       ├── ingestion_event.ex
│       └── ingestion.ex (extended)
└── zaq_web/
    ├── controllers/
    │   ├── google_auth_controller.ex
    │   └── google_drive_webhook_controller.ex
    └── live/bo/
        ├── google_drive_config_live.ex
        └── ingestion_events_live.ex

priv/repo/migrations/
├── XXX_add_google_drive_fields_to_channel_configs.exs
├── XXX_create_ingestion_watched_folders.exs
└── XXX_create_ingestion_events.exs

test/
├── zaq/channels/ingestion/google_drive_test.exs
├── zaq/channels/ingestion/google_drive/api_test.exs
└── zaq_web/live/bo/google_drive_config_live_test.exs
```

---

## Success Metrics

- **Connection Success Rate**: > 95% of OAuth attempts succeed
- **File Processing Latency**: < 30 seconds from change detection to ingestion
- **Sync Coverage**: All supported file types (PDF, DOCX, XLSX, PPTX, images) process successfully
- **Error Recovery**: Failed events can be retried with < 5% permanent failure rate
- **Watch Channel Uptime**: < 1% missed change notifications due to expired watch channels

This roadmap provides a complete implementation plan for the Google Drive ingestion channel, following the existing patterns in the Zaq codebase and ensuring a robust, scalable solution.
