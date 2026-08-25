defmodule Zaq.Storage.Api do
  @moduledoc """
  Storage role boundary module used by `Zaq.NodeRouter.dispatch/1`.
  """

  @behaviour Zaq.InternalBoundaries

  alias Zaq.Event
  alias Zaq.InternalBoundaries
  alias Zaq.Storage

  @impl true
  def handle_event(%Event{} = event, :list_volumes, _context) do
    %{event | response: Storage.list_volumes(event.opts)}
  end

  def handle_event(%Event{} = event, :volumes_configured?, _context) do
    %{event | response: Storage.volumes_configured?(event.opts)}
  end

  def handle_event(
        %Event{request: %{volume: volume, path: path}} = event,
        :list_entries,
        _context
      )
      when is_binary(volume) and is_binary(path) do
    %{event | response: Storage.list_entries(volume, path, event.opts)}
  end

  def handle_event(%Event{request: %{volume: volume, path: path}} = event, :file_info, _context)
      when is_binary(volume) and is_binary(path) do
    %{event | response: Storage.file_info(volume, path, event.opts)}
  end

  def handle_event(
        %Event{request: %{volume: volume, path: path}} = event,
        :create_directory,
        _context
      )
      when is_binary(volume) and is_binary(path) do
    %{event | response: Storage.create_directory(volume, path, event.opts)}
  end

  def handle_event(
        %Event{request: %{volume: volume, path: path, content: content}} = event,
        :save_file,
        _context
      )
      when is_binary(volume) and is_binary(path) and is_binary(content) do
    %{event | response: Storage.save_file(volume, path, content, event.opts)}
  end

  def handle_event(
        %Event{request: %{volume: volume, path: path, content: content}} = event,
        :upload_file,
        _context
      )
      when is_binary(volume) and is_binary(path) and is_binary(content) do
    %{event | response: Storage.upload_file(volume, path, content, event.opts)}
  end

  def handle_event(%Event{request: %{volume: volume, path: path}} = event, :delete_file, _context)
      when is_binary(volume) and is_binary(path) do
    %{event | response: Storage.delete_file(volume, path, event.opts)}
  end

  def handle_event(
        %Event{request: %{volume: volume, path: path}} = event,
        :delete_directory,
        _context
      )
      when is_binary(volume) and is_binary(path) do
    %{event | response: Storage.delete_directory(volume, path, event.opts)}
  end

  def handle_event(
        %Event{request: %{volume: volume, old_path: old_path, new_path: new_path}} = event,
        :rename_entry,
        _context
      )
      when is_binary(volume) and is_binary(old_path) and is_binary(new_path) do
    %{event | response: Storage.rename_entry(volume, old_path, new_path, event.opts)}
  end

  def handle_event(%Event{request: %{file_id: file_id}} = event, :describe_document, _context)
      when is_binary(file_id) do
    %{event | response: Storage.describe_document(file_id, event.opts)}
  end

  def handle_event(%Event{request: %{params: params}} = event, :list_documents, _context)
      when is_map(params) do
    %{event | response: Storage.list_documents(params, event.opts)}
  end

  def handle_event(
        %Event{request: %{file_id: file_id} = request} = event,
        :materialize_document,
        _context
      )
      when is_binary(file_id) do
    %{event | response: Storage.materialize_document(request, event.opts)}
  end

  def handle_event(%Event{request: request} = event, :persist_document, _context)
      when is_map(request) do
    %{event | response: Storage.persist_document(request, event.opts)}
  end

  def handle_event(%Event{request: request} = event, :update_document, _context)
      when is_map(request) do
    %{event | response: Storage.update_document(request, event.opts)}
  end

  def handle_event(%Event{request: %{file_id: file_id}} = event, :delete_document, _context)
      when is_binary(file_id) do
    %{event | response: Storage.delete_document(file_id, event.opts)}
  end

  def handle_event(
        %Event{request: %{file_id: file_id}} = event,
        :list_document_grants,
        _context
      )
      when is_binary(file_id) do
    %{event | response: Storage.list_document_grants(file_id)}
  end

  def handle_event(%Event{request: %{params: params}} = event, :search_documents, _context)
      when is_map(params) do
    %{event | response: Storage.search_documents(params, event.opts)}
  end

  def handle_event(%Event{request: request} = event, :volume_stats, _context)
      when is_map(request) do
    %{event | response: Storage.volume_stats(event.opts)}
  end

  @impl true
  def handle_event(%Event{} = event, action, _context),
    do: InternalBoundaries.default_handle_event(event, action)
end
