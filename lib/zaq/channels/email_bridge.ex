defmodule Zaq.Channels.EmailBridge do
  @moduledoc """
  Bridge for the email channel.

  Delivers `%Outgoing{}` via SMTP using the notification SMTP implementation.
  Connection details are not required — SMTP settings are read from
  `channel_configs.settings` under provider `email:smtp`.

  `to_internal/2` is a stub for future inbound email parsing.
  """

  require Logger

  alias Zaq.Channels.{Router, Supervisor}
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.NodeRouter

  @doc "Converts an email adapter payload to the internal `%Incoming{}` format."
  @spec to_internal(map(), map()) :: Incoming.t() | {:error, term()}
  def to_internal(params, connection_details)
      when is_map(params) and is_map(connection_details) do
    with {:ok, adapter} <- resolve_adapter(connection_details) do
      adapter.to_internal(params, connection_details)
    end
  end

  def to_internal(_params, _connection_details), do: {:error, :invalid_email_payload}

  @doc "Starts inbound email runtime processes for a channel config."
  def start_runtime(config) do
    bridge_id = default_bridge_id(config)

    with {:ok, adapter} <- adapter_for(config.provider),
         {:ok, {state_spec, listeners}} <-
           adapter.runtime_specs(
             config,
             bridge_id,
             sink_mfa: {__MODULE__, :from_listener, []},
             sink_opts: [bridge_id: bridge_id]
           ),
         {:ok, _runtime} <-
           Supervisor.start_runtime(
             bridge_id,
             state_spec,
             listeners
           ) do
      :ok
    else
      {:error, :already_running} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stops IMAP runtime processes for an email:imap config."
  def stop_runtime(config) do
    case Supervisor.stop_bridge_runtime(config, default_bridge_id(config)) do
      :ok -> :ok
      {:error, :not_running} -> :ok
      other -> other
    end
  end

  @doc "Listener sink callback for incoming adapter payloads."
  def from_listener(config, payload, sink_opts)
      when is_map(payload) and is_list(sink_opts) do
    connection = sink_opts |> Enum.into(%{}) |> Map.put(:config, config)

    with %Incoming{} = incoming <- to_internal(payload, connection),
         outgoing <- run_pipeline(incoming),
         :ok <- deliver_outgoing(outgoing),
         :ok <- persist_from_incoming(incoming, outgoing.metadata) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "[EmailBridge] Failed to process inbound message provider=#{config.provider} reason=#{inspect(reason)}"
        )

        {:error, reason}

      other ->
        Logger.warning(
          "[EmailBridge] Failed to process inbound message provider=#{config.provider} reason=#{inspect(other)}"
        )

        {:error, other}
    end
  end

  @doc """
  Delivers `%Outgoing{}` as an email to `outgoing.channel_id` (the recipient address).

  Reads subject and html_body from `outgoing.metadata` (keys `:subject` / `"subject"`
  and `:html_body` / `"html_body"`). Falls back to a default subject if missing.
  """
  @spec send_reply(Outgoing.t(), map()) :: :ok | {:error, term()}
  def send_reply(%Outgoing{} = outgoing, _connection_details) do
    alias Zaq.Engine.Notifications.EmailNotification

    subject = get_meta(outgoing.metadata, "subject", :subject) || "Notification from ZAQ"
    html_body = get_meta(outgoing.metadata, "html_body", :html_body)
    payload = %{"subject" => subject, "body" => outgoing.body, "html_body" => html_body}

    EmailNotification.send_notification(outgoing.channel_id, payload, %{})
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp default_bridge_id(config), do: "#{config.provider}_#{config.id}"

  defp resolve_adapter(connection_details) do
    case Map.get(connection_details, :adapter) || Map.get(connection_details, "adapter") do
      module when is_atom(module) and not is_nil(module) -> {:ok, module}
      _ -> adapter_from_provider(connection_details)
    end
  end

  defp adapter_from_provider(connection_details) do
    provider =
      connection_details
      |> Map.get(:config)
      |> case do
        %{provider: provider} -> provider
        _ -> "email:imap"
      end

    adapter_for(provider)
  end

  defp adapter_for(provider) do
    with key when not is_nil(key) <- provider_key(provider),
         adapter when is_atom(adapter) <-
           Application.get_env(:zaq, :channels, %{}) |> get_in([key, :adapter]) do
      {:ok, adapter}
    else
      _ -> {:error, {:unsupported_provider, provider}}
    end
  end

  defp provider_key(provider) when is_atom(provider), do: provider

  defp provider_key(provider) when is_binary(provider) do
    String.to_existing_atom(provider)
  rescue
    ArgumentError -> :email
  end

  defp run_pipeline(%Incoming{} = msg) do
    module = pipeline_module()

    if module == Zaq.Agent.Pipeline do
      NodeRouter.call(:agent, module, :run, [msg, []])
    else
      module.run(msg, [])
    end
  end

  defp deliver_outgoing(%Outgoing{} = outgoing) do
    module = router_module()

    if module == Router do
      NodeRouter.call(:channels, module, :deliver, [outgoing])
    else
      module.deliver(outgoing)
    end
  end

  defp persist_from_incoming(%Incoming{} = incoming, metadata) when is_map(metadata) do
    module = conversations_module()

    if module == Zaq.Engine.Conversations do
      NodeRouter.call(:engine, module, :persist_from_incoming, [incoming, metadata])
    else
      module.persist_from_incoming(incoming, metadata)
    end
  end

  defp pipeline_module,
    do: Application.get_env(:zaq, :email_bridge_pipeline_module, Zaq.Agent.Pipeline)

  defp router_module,
    do: Application.get_env(:zaq, :email_bridge_router_module, Router)

  defp conversations_module,
    do: Application.get_env(:zaq, :email_bridge_conversations_module, Zaq.Engine.Conversations)

  # Handles both atom and string-keyed metadata (Oban args arrive as string keys).
  defp get_meta(metadata, string_key, atom_key) do
    Map.get(metadata, atom_key) || Map.get(metadata, string_key)
  end
end
