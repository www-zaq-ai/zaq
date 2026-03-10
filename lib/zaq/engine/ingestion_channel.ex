defmodule Zaq.Engine.IngestionChannel do
  @moduledoc """
  Behaviour contract for ingestion channel adapters.

  An ingestion channel is a source of documents that ZAQ pulls into its
  knowledge base. Adapters can be polling-based (e.g. scheduled Oban jobs),
  event-driven (e.g. webhooks), or both.

  ## Examples of adapters
  - `Zaq.Channels.Ingestion.GoogleDrive`
  - `Zaq.Channels.Ingestion.SharePoint`

  ## Polling-based adapters
  Implement `schedule_sync/1` to register an Oban job that calls `list_documents/1`
  and `fetch_document/2` on a schedule.

  ## Event-driven adapters
  Implement `handle_event/2` to react to push notifications (e.g. webhooks)
  from the source platform.

  Both `schedule_sync/1` and `handle_event/2` are optional callbacks.
  """

  @type config :: map()
  @type state :: any()
  @type doc_meta :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          optional(:mime_type) => String.t(),
          optional(:modified_at) => DateTime.t(),
          optional(atom()) => any()
        }

  @doc """
  Authenticates with the source and returns an opaque state used by
  subsequent callbacks.
  """
  @callback connect(config()) :: {:ok, state()} | {:error, term()}

  @doc """
  Releases any resources or connections held by the adapter.
  """
  @callback disconnect(state()) :: :ok

  @doc """
  Returns a list of document metadata available from the source.
  Adapters should return only new or changed documents when possible.
  """
  @callback list_documents(state()) :: {:ok, [doc_meta()]} | {:error, term()}

  @doc """
  Fetches the raw content of a single document identified by its metadata.
  """
  @callback fetch_document(doc_meta(), state()) :: {:ok, binary()} | {:error, term()}

  @doc """
  Optional. Registers a scheduled sync job (e.g. via Oban) for polling adapters.
  Called once on adapter startup.
  """
  @callback schedule_sync(config()) :: :ok

  @doc """
  Optional. Handles a push event from the source platform for event-driven adapters.
  """
  @callback handle_event(event :: map(), state()) :: :ok | {:error, term()}

  @optional_callbacks schedule_sync: 1, handle_event: 2
end
