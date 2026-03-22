defmodule Zaq.Engine.Notifications.Adapters.MattermostAdapter do
  @moduledoc """
  Mattermost notification adapter.

  Posts a message to a Mattermost channel using the existing
  `Zaq.Channels.Retrieval.Mattermost.API` client (which loads its config
  from `ChannelConfig`).

  ## on_reply dispatch

  If `metadata["on_reply"]` is present after a successful post, the adapter
  dispatches an Oban job via module dispatch:

      apply(module, :new, [args]) |> Oban.insert()

  The `"module"` value must be a string of an existing atom (e.g.
  `"Elixir.MyApp.SomeWorker"`). If the module is unknown, a warning is
  logged and `:ok` is still returned — the message was sent successfully.
  """

  @behaviour Zaq.Engine.NotificationAdapter

  require Logger

  @impl true
  def platform, do: "mattermost"

  @impl true
  def send(identifier, payload, metadata) do
    message = format_message(payload)

    case mattermost_api().send_message(identifier, message) do
      {:ok, _} ->
        dispatch_on_reply(metadata)
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

  defp format_message(%{"subject" => subject, "body" => body}) do
    "**#{subject}**\n\n#{body}"
  end

  defp format_message(%{"body" => body}), do: body

  defp dispatch_on_reply(%{"on_reply" => %{"module" => mod_str, "args" => args}}) do
    module = String.to_existing_atom(mod_str)
    module.new(args) |> Oban.insert()
  rescue
    ArgumentError ->
      Logger.warning(
        "[MattermostAdapter] on_reply module #{inspect(mod_str)} is not loaded — skipping callback"
      )
  end

  defp dispatch_on_reply(_metadata), do: :ok
end
