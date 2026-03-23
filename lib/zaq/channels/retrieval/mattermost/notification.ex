defmodule Zaq.Channels.Retrieval.Mattermost.Notification do
  @moduledoc """
  Mattermost notification delivery.

  Implements `Zaq.Engine.NotificationAdapter` — posts a message to a Mattermost
  channel using the existing `Zaq.Channels.Retrieval.Mattermost.API` client,
  which loads its config from `ChannelConfig`.

  ## on_reply dispatch

  If `metadata["on_reply"]` is present after a successful post, an Oban job is
  dispatched via module dispatch:

      apply(module, :new, [args]) |> Oban.insert()

  The `"module"` value must be a string of an existing atom (e.g.
  `"Elixir.MyApp.SomeWorker"`). If the module is unknown, a warning is logged
  and `:ok` is still returned — the message was sent successfully.
  """

  @behaviour Zaq.Engine.NotificationAdapter

  require Logger

  @impl true
  def send_notification(identifier, payload, metadata) do
    message = format_message(payload)

    case mattermost_api().send_message(identifier, message) do
      {:ok, post} ->
        post_id = Map.get(post, "id") || Map.get(post, :id)
        dispatch_on_reply(metadata, post_id)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp mattermost_api do
    Application.get_env(
      :zaq,
      :mattermost_api_module,
      Zaq.Channels.Retrieval.Mattermost.API
    )
  end

  defp format_message(%{"body" => body}), do: body

  defp dispatch_on_reply(%{"on_reply" => %{"module" => mod_str, "args" => args}}, post_id) do
    module = String.to_existing_atom(mod_str)
    full_args = if post_id, do: Map.put(args, "post_id", post_id), else: args

    case module.new(full_args) |> Oban.insert() do
      {:ok, job} ->
        Logger.info(
          "[Mattermost.Notification] on_reply job #{job.id} enqueued for #{inspect(mod_str)}"
        )

      {:error, changeset} ->
        Logger.warning(
          "[Mattermost.Notification] failed to enqueue on_reply for #{inspect(mod_str)}: #{inspect(changeset.errors)}"
        )
    end
  rescue
    e ->
      Logger.warning(
        "[Mattermost.Notification] on_reply dispatch failed for #{inspect(mod_str)}: #{Exception.message(e)}"
      )
  end

  defp dispatch_on_reply(_metadata, _post_id), do: :ok
end
