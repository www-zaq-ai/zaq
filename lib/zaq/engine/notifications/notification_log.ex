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

  `append_attempt/3` uses a raw `Repo.query!/2` with a Postgres `||` fragment
  to append to `channels_tried`. This is race-safe on concurrent Oban retries.
  """

  use Ecto.Schema

  import Ecto.Changeset

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
  @spec append_attempt(integer(), String.t(), :ok | {:error, term()}) :: :ok
  def append_attempt(log_id, platform, result) do
    {status_str, error_str} =
      case result do
        :ok -> {"ok", nil}
        {:error, reason} -> {"error", inspect(reason)}
      end

    attempted_at = DateTime.utc_now() |> DateTime.to_iso8601()

    %{num_rows: 1} =
      Repo.query!(
        """
        UPDATE notification_logs
        SET channels_tried = channels_tried || jsonb_build_array(
          jsonb_build_object(
            'platform', $1::text,
            'status',   $2::text,
            'error',    $3::text,
            'attempted_at', $4::text
          )
        )
        WHERE id = $5
        """,
        [platform, status_str, error_str, attempted_at, log_id]
      )

    :ok
  end

  @doc """
  Transitions the log's status, enforcing allowed transitions.

  Valid transitions: `"pending"` → `"sent"`, `"skipped"`, `"failed"`.

  Returns `{:ok, updated_log}` or `{:error, :invalid_transition}`.
  """
  @spec transition_status(%__MODULE__{}, String.t()) ::
          {:ok, %__MODULE__{}} | {:error, :invalid_transition}
  def transition_status(%__MODULE__{status: current_status} = log, new_status) do
    allowed = Map.get(@valid_transitions, current_status, [])

    if new_status in allowed do
      log
      |> status_changeset(%{status: new_status})
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, updated}
        {:error, _changeset} = err -> err
      end
    else
      {:error, :invalid_transition}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

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

  defp status_changeset(log, attrs) do
    log
    |> cast(attrs, [:status])
    |> validate_required([:status])
    |> validate_inclusion(:status, @valid_statuses)
  end
end
