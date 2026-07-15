defmodule Zaq.Engine.Notifications.NotificationLog do
  @moduledoc """
  Ecto schema for notification audit logs.

  Each `notify/1` call creates one log record. The payload (subject + body) is
  stored here — Oban job args carry only the `log_id`.

  ## Status lifecycle

      pending → sent | skipped | failed

  Use `transition_status/2` for all status changes — never update `:status`
  directly with `Repo.update`.

  ## Atomic JSONB append

  `append_attempt/4` uses a raw `Repo.query!/2` with a Postgres `||` fragment
  to append to `channels_tried`.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  require Logger

  alias Zaq.Repo

  @valid_statuses ~w(pending sent skipped failed)
  @valid_transitions %{"pending" => ~w(sent skipped failed)}

  schema "notification_logs" do
    field :sender, :string
    field :recipient_name, :string
    field :recipient_ref_type, :string
    field :recipient_ref_id, :integer
    field :payload, :map
    field :channels_tried, Zaq.Types.JsonArray
    field :status, :string, default: "pending"
    field :threading, :map
    field :thread_key, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Creates a new notification log record. Status defaults to `"pending"`.
  """
  @spec create_log(map()) :: {:ok, %__MODULE__{}} | {:error, Ecto.Changeset.t()}
  def create_log(attrs) do
    attrs_with_defaults = Map.put_new(attrs, :channels_tried, [])

    %__MODULE__{}
    |> changeset(attrs_with_defaults)
    |> Repo.insert()
  end

  @doc """
  Atomically appends a channel attempt entry to `channels_tried` using a
  Postgres JSONB concatenation fragment. Safe for concurrent Oban retries.
  """
  @spec append_attempt(integer(), term(), :ok | {:error, term()}) :: :ok
  def append_attempt(log_id, platform, result), do: append_attempt(log_id, platform, nil, result)

  @spec append_attempt(integer(), term(), term(), :ok | {:error, term()}) :: :ok
  def append_attempt(log_id, platform, identifier, result) do
    {status_str, error_str} =
      case result do
        :ok -> {"ok", nil}
        {:error, reason} -> {"error", inspect(reason)}
      end

    attempted_at = DateTime.utc_now() |> DateTime.to_iso8601()

    case Repo.query!(
           """
           UPDATE notification_logs
           SET channels_tried = channels_tried || jsonb_build_array(
            jsonb_build_object(
               'platform', $1::text,
               'identifier', $2::text,
               'status',   $3::text,
               'error',    $4::text,
               'attempted_at', $5::text
             )
           )
           WHERE id = $6
           """,
           [to_text(platform), to_text(identifier), status_str, error_str, attempted_at, log_id]
         ) do
      %{num_rows: 1} ->
        :ok

      %{num_rows: 0} ->
        Logger.warning("[NotificationLog] append_attempt: log #{log_id} not found")
        :ok
    end
  end

  @doc """
  Transitions the log's status, enforcing allowed transitions.

  Valid transitions: `"pending"` → `"sent"`, `"skipped"`, `"failed"`.

  Returns `{:ok, updated_log}` or `{:error, :invalid_transition}`.
  """
  @spec transition_status(%__MODULE__{}, String.t()) ::
          {:ok, %__MODULE__{}} | {:error, :invalid_transition | :stale_record}
  def transition_status(%__MODULE__{status: current_status} = log, new_status) do
    allowed = Map.get(@valid_transitions, current_status, [])

    if new_status in allowed do
      {count, _} =
        Repo.update_all(
          from(l in __MODULE__, where: l.id == ^log.id and l.status == ^current_status),
          set: [status: new_status]
        )

      case count do
        1 -> {:ok, %{log | status: new_status}}
        0 -> {:error, :stale_record}
      end
    else
      {:error, :invalid_transition}
    end
  end

  @doc """
  Records the threading anchor of a delivered message on its log row.

  Called on the `sent` transition and never before: an anchor may only describe a
  message the recipient actually received, or the next send would chain onto a
  message that does not exist.

  The anchor is the opaque map from the bridge's delivery receipt, stored and
  returned verbatim — only the provider bridge interprets its contents. The log —
  not the conversation message — is the source of truth for the outbound chain,
  because it is written by the same code that saw delivery succeed. Persisting the
  chain anywhere downstream (a workflow step, an edge mapping) makes threading
  depend on how a DAG happens to be wired.
  """
  @spec record_threading(%__MODULE__{}, String.t() | nil, map()) :: :ok
  def record_threading(%__MODULE__{}, nil, _anchor), do: :ok
  def record_threading(%__MODULE__{}, _key, anchor) when map_size(anchor) == 0, do: :ok

  def record_threading(%__MODULE__{id: id}, thread_key, anchor) when is_map(anchor) do
    {count, _} =
      Repo.update_all(
        from(l in __MODULE__, where: l.id == ^id),
        set: [threading: anchor, thread_key: thread_key]
      )

    if count == 0, do: Logger.warning("[NotificationLog] record_threading: log #{id} not found")

    :ok
  end

  @doc """
  Resolves the threading anchor for the next send to `person_id` under `thread_key`.

  Returns the anchor of the most recently **sent** message in that thread, exactly
  as the delivering bridge recorded it, or `nil` when no prior send exists — the
  next send then opens the thread. The map is opaque here; only the provider
  bridge interprets its keys.

  Ordered by `id` (monotonic) rather than `inserted_at`, so sub-second sends in the
  same thread still resolve to a deterministic parent.
  """
  @spec thread_anchor(integer() | nil, String.t() | nil) :: map() | nil
  def thread_anchor(nil, _thread_key), do: nil
  def thread_anchor(_person_id, nil), do: nil

  def thread_anchor(person_id, thread_key) do
    from(l in __MODULE__,
      where:
        l.recipient_ref_type == "person" and
          l.recipient_ref_id == ^person_id and
          l.thread_key == ^thread_key and
          l.status == "sent" and
          not is_nil(l.threading),
      order_by: [desc: l.id],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> nil
      log -> to_anchor(log.threading)
    end
  end

  defp to_anchor(%{"message_id" => message_id} = anchor) when is_binary(message_id), do: anchor
  defp to_anchor(_threading), do: nil

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp to_text(nil), do: nil
  defp to_text(value), do: to_string(value)

  defp changeset(log, attrs) do
    log
    |> cast(attrs, [
      :sender,
      :recipient_name,
      :recipient_ref_type,
      :recipient_ref_id,
      :payload,
      :channels_tried,
      :status
    ])
    |> validate_required([:sender, :payload])
    |> validate_inclusion(:status, @valid_statuses)
  end
end
