defmodule Zaq.Channels.WebBridge do
  @moduledoc """
  Bridge for normalized web consumers, including BO ChatLive and the web widget.

  It translates shared web Message values into canonical `%Incoming{}` messages,
  delegates non-message Commands through Engine role actions, and delivers
  `%Outgoing{}` responses through the configured web delivery contract.

  Each ChatLive session supplies a trusted delivery descriptor. Status updates
  use `:upsert_message` and final results use `send_reply/2`; both publish only
  normalized semantic responses.

  Widgets use config-bound adapter context and direct transport delivery for
  independent saved-user acknowledgements and assistant streams. Accepted user
  records are projected from authorized canonical history and shared with all tabs
  on the resolved recipient destination. Idle widget init creates
  no chat. Transport runtimes are constructed by the dynamically registered
  adapter through the existing Bridge lifecycle. This bridge binds the shared
  protocol and ingress sink; transport policy and readiness belong to the adapter.

  The callback declarations below describe the external adapter this module consumes,
  not bridge lifecycle callbacks (which belong to `Zaq.Channels.Bridge`). Implementations
  are selected through provider registration and need no compile-time ZAQ dependency.
  Shared infrastructure receives trusted process options, never browser settings.
  """

  use Zaq.Channels.Bridge
  @behaviour Zaq.Channels.Bridge
  @behaviour Zaq.Channels.CommunicationBridge

  alias Zaq.Channels.{Bridge, CommunicationBridge}
  alias Zaq.Channels.Web.{Command, Context, Delivery, Response}
  alias Zaq.Channels.Web.Message, as: WebMessage
  alias Zaq.Channels.Web.SyncReply
  alias Zaq.Engine.Conversations.{Conversation, MessageRating}
  alias Zaq.Engine.Conversations.Message, as: ConversationMessage
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Event
  alias Zaq.Events.Helper
  alias Zaq.NodeRouter

  @widget_events %{
    user_message: "response.user_message",
    typing: "response.typing",
    message_create: "response.message.create",
    message_edit: "response.message.edit",
    message_step: "response.message.step",
    message_complete: "response.message.complete",
    message_failed: "response.message.failed",
    error: "response.error"
  }

  @callback infrastructure_child_specs(keyword()) ::
              {:ok, [Supervisor.child_spec()]} | {:error, term()}
  @callback build_runtime_specs(map(), map()) :: {:ok, {map() | nil, [map()]}} | {:error, term()}
  @callback ingress_status(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  @callback installation(map() | pos_integer(), String.t(), keyword()) ::
              {:ok, String.t()} | {:error, atom()}
  @optional_callbacks infrastructure_child_specs: 1,
                      ingress_status: 2,
                      installation: 3

  @doc "Fetches a verified sender profile from its connector-scoped adapter."
  @spec fetch_profile(String.t(), map()) :: {:ok, map()} | {:error, term()}
  @impl Zaq.Channels.CommunicationBridge
  def fetch_profile(sender, %{channel_config_id: id} = details)
      when is_binary(sender) and is_integer(id) and id > 0 do
    with %{sender_id: ^sender, channel_config_id: ^id, profile: profile}
         when is_map(profile) <- Map.get(details, :profile_context),
         true <-
           Enum.all?([:full_name, :email, :phone], fn key ->
             value = metadata_value(profile, key)

             is_nil(value) or
               (is_binary(value) and String.valid?(value) and byte_size(value) <= 1000)
           end) do
      {:ok,
       %{
         channel_id: sender,
         display_name: metadata_value(profile, :full_name),
         email: metadata_value(profile, :email),
         phone: metadata_value(profile, :phone)
       }}
    else
      nil -> {:error, :not_found}
      _ -> {:error, :invalid_profile}
    end
  end

  def fetch_profile(_sender, _details), do: {:error, :missing_connection_details}

  @doc "Resolves the web transport adapter registered for the provider."
  @spec adapter_for(atom() | String.t(), keyword()) :: {:ok, module()} | {:error, atom()}
  def adapter_for(provider, opts \\ []) do
    case Bridge.provider_config(provider, opts) do
      %{adapter: adapter} when is_atom(adapter) and not is_nil(adapter) ->
        if Code.ensure_loaded?(adapter), do: {:ok, adapter}, else: {:error, :adapter_unavailable}

      _ ->
        {:error, :unsupported}
    end
  end

  defp infrastructure_child_specs(provider, opts) do
    case adapter_for(provider, opts) do
      {:ok, adapter} ->
        if function_exported?(adapter, :infrastructure_child_specs, 1) do
          normalize_infrastructure_specs(
            adapter.infrastructure_child_specs(infrastructure_options(provider, opts))
          )
        else
          {:ok, []}
        end

      {:error, :unsupported} ->
        {:ok, []}

      {:error, _} ->
        {:error, :provider_infrastructure_start_failed}
    end
  rescue
    _ -> {:error, :provider_infrastructure_start_failed}
  catch
    _, _ -> {:error, :provider_infrastructure_start_failed}
  end

  defp infrastructure_options(provider, opts) do
    provider_opts =
      opts
      |> Keyword.get(:adapter_options, %{})
      |> Map.get(Bridge.provider_to_bridge_key(provider), [])

    options =
      Keyword.merge(Keyword.get(opts, :host_options, []), provider_opts)
      |> Keyword.put_new(:pubsub_server, Zaq.PubSub)
      |> Keyword.put_new(:scope, "/channels")

    if Bridge.provider_to_bridge_key(provider) == :web_widget,
      do: widget_infrastructure_options(options),
      else: options
  end

  defp widget_infrastructure_options(options) do
    # Membership is deployment policy, not a snapshot of currently connected peers.
    options =
      Keyword.update(options, :authentication, [replica_nodes: [node()]], fn authentication ->
        Keyword.put_new(authentication, :replica_nodes, [node()])
      end)

    if System.get_env("WIDGET_DEV_MODE") == "true" do
      Keyword.update(
        options,
        :session,
        [partitioned: false],
        &Keyword.put_new(&1, :partitioned, false)
      )
    else
      options
    end
  end

  defp normalize_infrastructure_specs({:ok, specs}) when is_list(specs), do: {:ok, specs}
  defp normalize_infrastructure_specs(_), do: {:error, :provider_infrastructure_start_failed}

  @impl Zaq.Channels.Bridge
  def build_runtime_specs({:provider, provider}, opts) do
    with {:ok, specs} <- infrastructure_child_specs(provider, opts) do
      {:ok, {nil, specs}}
    end
  end

  def build_runtime_specs(config, opts), do: super(config, opts)

  @impl Zaq.Channels.Bridge
  def build_runtime_specs(%{id: id} = config) when is_integer(id) and id > 0 do
    hooks = %{
      message: WebMessage,
      command: Command,
      context: Context,
      delivery: Delivery,
      response: Response,
      sink_mfa: {__MODULE__, :from_adapter, [%{id: id}]}
    }

    build_adapter_runtime(config, hooks)
  end

  def build_runtime_specs(_), do: {:error, :invalid_connector}

  defp build_adapter_runtime(config, hooks) do
    with {:ok, adapter} <- adapter_for(Map.get(config, :provider)),
         true <- function_exported?(adapter, :build_runtime_specs, 2) || {:error, :unsupported} do
      case adapter.build_runtime_specs(config, hooks) do
        {:ok, {state, listeners}} when (is_nil(state) or is_map(state)) and is_list(listeners) ->
          {:ok, {state, listeners}}

        {:error, reason} when is_atom(reason) ->
          {:error, reason}

        _ ->
          {:error, :invalid_runtime_specs}
      end
    end
  rescue
    _ -> {:error, :runtime_construction_failed}
  catch
    _, _ -> {:error, :runtime_construction_failed}
  end

  @impl Zaq.Channels.CommunicationBridge
  def channel_ingress_status(config), do: channel_ingress_status(config, [])

  @doc "Relays bounded ingress status to the provider's configured web transport."
  @spec channel_ingress_status(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def channel_ingress_status(%{enabled: false}, _opts),
    do: {:ok, %{status: :disabled, summary: "Disabled"}}

  def channel_ingress_status(%{provider: provider, id: id} = config, opts)
      when is_integer(id) and id > 0 do
    with {:ok, adapter} <- adapter_for(provider, opts),
         true <- function_exported?(adapter, :ingress_status, 2) || {:error, :unsupported} do
      task =
        Task.Supervisor.async_nolink(Zaq.TaskSupervisor, fn ->
          safe_ingress_status(adapter, config)
        end)

      case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, status}} -> {:ok, status}
        {:ok, {:error, :check_timeout}} -> unknown_ingress(:check_timeout)
        nil -> unknown_ingress(:check_timeout)
        _ -> unknown_ingress(:check_failed)
      end
    else
      _ -> unknown_ingress(:readiness_unsupported)
    end
  end

  def channel_ingress_status(_, _), do: {:error, :invalid_request}

  defp safe_ingress_status(adapter, config) do
    case adapter.ingress_status(config, timeout_ms: 2_000) do
      {:ok, %{status: state, summary: summary} = status}
      when state in [:ok, :pending, :error, :unknown, :disabled] and is_binary(summary) ->
        {:ok, status}

      {:error, :check_timeout} ->
        {:error, :check_timeout}

      _ ->
        {:error, :check_failed}
    end
  rescue
    _ -> {:error, :check_failed}
  catch
    _, _ -> {:error, :check_failed}
  end

  defp unknown_ingress(:readiness_unsupported),
    do:
      {:ok,
       %{
         status: :unknown,
         reason: :readiness_unsupported,
         summary: "Adapter does not support readiness checks"
       }}

  defp unknown_ingress(reason),
    do:
      {:ok,
       %{status: :unknown, reason: reason, summary: "Transport readiness cannot be verified"}}

  @impl Zaq.Channels.Bridge
  def capability_snapshot(config) do
    resolved =
      case adapter_for(config.provider) do
        {:ok, adapter} ->
          %{
            runtime: function_exported?(adapter, :build_runtime_specs, 2),
            installation: function_exported?(adapter, :installation, 3)
          }

        _ ->
          %{runtime: false, installation: false}
      end

    {:ok, %{required: [:runtime, :installation], resolved: resolved}}
  end

  @doc "Generates a bounded installation snippet through the confidential installation read."
  @spec installation(map(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def installation(%{op: :installation, config: %{id: id} = config, base_url: base_url}, opts)
      when is_integer(id) and id > 0 and is_binary(base_url) and byte_size(base_url) > 0 do
    with {:ok, adapter} <- adapter_for(config.provider, opts),
         true <- function_exported?(adapter, :installation, 3) || {:error, :unsupported} do
      normalize_installation(adapter.installation(config, base_url, scope: "/channels"))
    end
  rescue
    _ -> {:error, :installation_failed}
  catch
    _, _ -> {:error, :installation_failed}
  end

  def installation(_, _), do: {:error, :invalid_request}

  defp normalize_installation({:ok, snippet})
       when is_binary(snippet) and byte_size(snippet) in 1..32_768 do
    if String.valid?(snippet), do: {:ok, snippet}, else: {:error, :invalid_installation}
  end

  defp normalize_installation(_), do: {:error, :invalid_installation}

  @doc "Receives only shared payloads bound to the connector used at construction."
  @spec from_adapter(map(), WebMessage.t() | Command.t(), keyword()) :: term()
  def from_adapter(%{id: id}, payload, opts) when is_list(opts) do
    with %Context{consumer: :widget, channel_config_id: ^id} = context <-
           Keyword.get(opts, :context),
         true <- is_struct(payload, WebMessage) or is_struct(payload, Command) do
      event_opts = [action: :web_ingress, confidential: true]

      Event.new(%{payload: payload, context: context}, :channels, opts: event_opts)
      |> NodeRouter.dispatch()
      |> Map.fetch!(:response)
    else
      false -> {:error, :invalid_payload}
      _ -> {:error, :unauthorized}
    end
  end

  def from_adapter(_, _, _), do: {:error, :unauthorized}

  @impl Zaq.Channels.Bridge
  def start_runtime({:provider, _} = target), do: super(target)

  def start_runtime(%{provider: provider}) when provider in [:web, "web"], do: :ok

  def start_runtime(%{provider: provider} = config) do
    case Bridge.provider_config(provider) do
      %{adapter: _} ->
        case runtime_supervisor_module().lookup_runtime(runtime_bridge_id(config)) do
          {:ok, _runtime} -> :ok
          {:error, :not_running} -> super(config)
        end

      _ ->
        {:error, :unsupported}
    end
  end

  def start_runtime(_config), do: :ok

  @impl Zaq.Channels.Bridge
  def sync_runtime(%{enabled: true} = before, %{enabled: true} = after_config) do
    if before == after_config do
      start_runtime(after_config)
    else
      with :ok <- stop_runtime(before), do: start_runtime(after_config)
    end
  end

  def sync_runtime(before, after_config), do: super(before, after_config)

  @doc "Receives a normalized web payload through the common bridge ingress hooks."
  @spec from_listener(map(), WebMessage.t() | Command.t(), keyword()) ::
          Outgoing.t()
          | Response.t()
          | {:ok, Response.t()}
          | %{response: Response.t(), delivery_binding: Delivery.t()}
          | :ok
          | {:error, term()}
  def from_listener(config, payload, sink_opts) when is_map(config) and is_list(sink_opts) do
    Bridge.route_incoming(__MODULE__, config, payload, sink_opts)
  end

  @doc false
  def handle_from_listener(_config, %WebMessage{} = message, sink_opts) do
    with {:ok, message} <- WebMessage.new(Map.from_struct(message)),
         {:ok, context} <- fetch_context(sink_opts),
         {:ok, actor} <- ingress_actor(context) do
      if context.consumer == :widget do
        route_widget_message(message, context, sink_opts)
      else
        result = route_message(message, context, sink_opts, actor)
        maybe_deliver_ingress_failure(result, message, context)
        result
      end
    end
  end

  def handle_from_listener(_config, %Command{} = command, sink_opts) do
    with {:ok, command} <- Command.new(Map.from_struct(command)),
         {:ok, context} <- fetch_context(sink_opts),
         {:ok, actor} <- ingress_actor(context) do
      handle_command(command, context, sink_opts, actor)
    end
  end

  @doc "Builds canonical Incoming from a normalized message and trusted adapter context."
  @spec to_internal(WebMessage.t(), Context.t()) :: Incoming.t()
  @impl true
  def to_internal(%WebMessage{} = message, %Context{} = context) do
    widget? = context.consumer == :widget

    Incoming.new(%{
      content: message.content,
      channel_id: if(widget?, do: Ecto.UUID.generate(), else: message.channel),
      author_id: if(widget?, do: context.sender_id, else: message.author_id),
      author_name: message.author_name,
      message_id: message.message_id,
      provider: if(widget?, do: :web_widget, else: :web),
      person: if(widget?, do: nil, else: actor_person(context.actor)),
      attachments: message.attachments,
      content_filter: context.content_filter,
      routing_context: %{
        channel_config_id:
          context.channel_config_id || delivery_channel_config_id(context.delivery),
        identity_platform: if(widget?, do: "web_widget"),
        conversation_type: if(widget?, do: :one_to_one),
        topic_id: if(widget?, do: message.channel),
        conversation_id: message.conversation_id,
        provider_sent_at: message.timestamp,
        attributes: routing_attributes(context)
      },
      metadata: %{
        request_id: message.request_id,
        user_content: message.content,
        conversation_id: message.conversation_id,
        session_id: legacy_session_id(context.delivery)
      }
    })
  end

  @doc "Publishes a normalized final response to the trusted adapter destination."
  @spec send_reply(Outgoing.t(), map()) :: {:ok, map()} | {:error, term()}
  @impl true
  def send_reply(%Outgoing{} = outgoing, _connection_details) do
    case delivery_from_routing_context(outgoing.routing_context) do
      {:ok, nil} -> {:error, :missing_delivery_descriptor}
      {:ok, delivery} -> deliver_final(outgoing, delivery)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def upsert_message(_config, request, _connection_details) when is_map(request) do
    case delivery_from_routing_context(Map.get(request, :routing_context)) do
      {:ok, nil} ->
        {:error, :missing_delivery_descriptor}

      {:ok, delivery} ->
        deliver_status(request, delivery)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp status_stage(%{} = intent_meta) do
    case Map.get(intent_meta, :stage) || Map.get(intent_meta, "stage") do
      stage when is_atom(stage) -> stage
      _ -> :answering
    end
  end

  defp status_stage(_), do: :answering

  defp fetch_context(sink_opts) do
    case Keyword.get(sink_opts, :context) do
      %Context{} = context -> Context.validate(context)
      _ -> {:error, :missing_web_context}
    end
  end

  defp ingress_actor(%Context{consumer: :widget, sender_id: sender} = context)
       when is_binary(sender) and sender != "" do
    case widget_scope(context) do
      %{channel_config_id: id} when is_integer(id) and id > 0 -> {:ok, nil}
      _ -> {:error, :unauthorized}
    end
  end

  defp ingress_actor(%Context{consumer: :bo, actor: actor}) when is_map(actor), do: {:ok, actor}
  defp ingress_actor(_context), do: {:error, :unauthorized}

  defp pipeline_opts(%Context{} = context, sink_opts) do
    [
      history: context.history,
      skip_permissions: MapSet.member?(context.capabilities, :skip_permissions),
      node_router: Keyword.get(sink_opts, :node_router, NodeRouter),
      notify_execution_lifecycle: context.consumer == :widget
    ]
  end

  defp node_router_opts(sink_opts, mode),
    do: [node_router: Keyword.get(sink_opts, :node_router, NodeRouter), agent_hop_type: mode]

  defp route_message(message, context, sink_opts, actor) do
    with {:ok, incoming, actor} <- prepare_message(message, context, sink_opts, actor) do
      opts = node_router_opts(sink_opts, message.mode)

      opts =
        if context.consumer == :widget,
          do:
            Keyword.merge(opts,
              channel_config_id: incoming.routing_context.channel_config_id
            ),
          else: opts

      CommunicationBridge.route_incoming_message(
        incoming,
        pipeline_opts(context, sink_opts),
        actor,
        opts
      )
    end
  rescue
    _error -> {:error, :dispatch_error}
  catch
    _kind, _reason -> {:error, :dispatch_error}
  end

  defp prepare_message(message, %Context{consumer: :bo} = context, _opts, actor),
    do: {:ok, to_internal(message, context), actor}

  defp prepare_message(message, %Context{consumer: :widget} = context, sink_opts, _actor) do
    if is_nil(message.author_id) or message.author_id == context.sender_id do
      incoming =
        message |> to_internal(context) |> CommunicationBridge.put_conversation_identity()

      request =
        widget_scope(context)
        |> Map.merge(%{
          operation: :prepare,
          incoming: incoming,
          prompt_context: message.prompt_context
        })

      case dispatch_channel_conversations(request, context, sink_opts) do
        {:ok, %Incoming{} = incoming} -> {:ok, incoming, %{person: incoming.person}}
        {:error, _} = error -> error
        _ -> {:error, :conversation_unavailable}
      end
    else
      {:error, :unauthorized}
    end
  end

  defp route_widget_message(
         message,
         %Context{delivery: %Delivery{} = delivery} = context,
         sink_opts
       ) do
    with :ok <- validate_widget_events(delivery),
         {:ok, incoming, actor} <- prepare_message(message, context, sink_opts, nil) do
      delivery = %{
        delivery
        | conversation_id: incoming.routing_context.conversation_id,
          message_id: Ecto.UUID.generate()
      }

      dispatch = fn destination ->
        attributes =
          Map.put(
            incoming.routing_context.attributes,
            "web_delivery",
            Delivery.reference(destination)
          )

        scoped = %{
          incoming
          | routing_context: %{incoming.routing_context | attributes: attributes}
        }

        bound_context = %{context | delivery: destination}
        result = dispatch_widget_message(scoped, bound_context, sink_opts, actor)

        acknowledge_widget_input(result, message, bound_context, sink_opts)
      end

      widget_reply(message, delivery, dispatch, sink_opts)
    end
  rescue
    _error -> {:error, :dispatch_error}
  catch
    _kind, _reason -> {:error, :dispatch_error}
  end

  defp route_widget_message(message, context, _sink_opts) do
    if is_nil(message.author_id) or message.author_id == context.sender_id,
      do: {:error, :missing_delivery_descriptor},
      else: {:error, :unauthorized}
  end

  defp dispatch_widget_message(incoming, context, sink_opts, actor) do
    result =
      CommunicationBridge.route_incoming_message(
        incoming,
        pipeline_opts(context, sink_opts),
        actor,
        node_router_opts(sink_opts, :async) ++
          [
            channel_config_id: incoming.routing_context.channel_config_id,
            include_routing_disposition: true
          ]
      )

    case result do
      {:ok, :no_answer} ->
        {:ok, response} =
          Response.new(%{
            protocol_version: 2,
            request_id: metadata_value(incoming.metadata, :request_id),
            conversation_id: context.delivery.conversation_id,
            type: :status,
            payload: %{accepted: true, created: false}
          })

        {:ok, response}

      _ ->
        result
    end
  end

  defp widget_reply(%WebMessage{mode: :sync} = message, delivery, dispatch, sink_opts) do
    response = SyncReply.run(delivery, message.request_id, dispatch, widget_timeout(sink_opts))
    %{response | payload: Map.put(response.payload, :created, is_nil(message.conversation_id))}
  end

  defp widget_reply(_message, delivery, dispatch, _sink_opts) do
    dispatch.(delivery)
  end

  defp acknowledge_widget_input(result, %WebMessage{mode: :sync}, _context, _opts), do: result
  defp acknowledge_widget_input({:error, _} = error, _message, _context, _opts), do: error

  defp acknowledge_widget_input(_result, message, context, opts) do
    request =
      widget_scope(context)
      |> Map.merge(%{
        operation: :accepted_message,
        conversation_id: context.delivery.conversation_id,
        external_message_id: message.message_id
      })

    with {:ok, saved} <- dispatch_channel_conversations(request, context, opts),
         %Response{} = receipt <-
           submission_receipt(message, context.delivery, widget_history_message(saved)),
         :ok <- publish_user_message(context.delivery, receipt) do
      {:ok, receipt}
    else
      _ ->
        error = error_response(message, :acknowledgement_unavailable, 2)

        %{
          error
          | conversation_id: context.delivery.conversation_id,
            payload: Map.put(error.payload, :outcome, :unknown)
        }
    end
  end

  defp publish_user_message(delivery, receipt) do
    case Delivery.event_name(delivery, :user_message) do
      {:ok, event} ->
        Phoenix.PubSub.broadcast(
          Zaq.PubSub,
          delivery.topic,
          {:web_response, event, %{receipt | type: :user_message}}
        )

      # Legacy trusted descriptors can still use the direct receipt. New bindings
      # always include the accepted-user event mapping.
      {:error, :unsupported_event} ->
        :ok
    end
  end

  defp submission_receipt(message, delivery, saved) do
    created = is_nil(message.conversation_id)

    {:ok, response} =
      Response.new(%{
        protocol_version: 2,
        request_id: message.request_id,
        conversation_id: delivery.conversation_id,
        type: if(created, do: :conversation_created, else: :status),
        payload: %{accepted: true, created: created, user_message: saved}
      })

    response
  end

  defp validate_widget_events(delivery) do
    required = Map.keys(@widget_events) -- [:user_message]

    if Enum.all?(required, &match?({:ok, _}, Delivery.event_name(delivery, &1))),
      do: :ok,
      else: {:error, :incomplete_event_mapping}
  end

  defp widget_timeout(opts) do
    case Zaq.Config.get(:zaq, :web_widget_sync_timeout_ms, 30_000, opts) do
      value when is_integer(value) and value > 0 and value <= 900_000 -> value
      _ -> 30_000
    end
  end

  defp maybe_deliver_ingress_failure(%Outgoing{} = outgoing, message, %Context{} = context) do
    if metadata_value(outgoing.metadata || %{}, :error) == true do
      outgoing = %{
        outgoing
        | in_reply_to: outgoing.in_reply_to || message.message_id,
          metadata:
            Map.merge(
              %{
                request_id: message.request_id,
                user_content: message.content,
                conversation_id: message.conversation_id
              },
              outgoing.metadata || %{}
            )
      }

      case context.delivery do
        %Delivery{} = delivery -> deliver_final(outgoing, delivery)
        _ -> :ok
      end
    else
      :ok
    end
  end

  defp maybe_deliver_ingress_failure({:error, reason}, message, %Context{} = context) do
    with %Delivery{} = delivery <- context.delivery,
         {:ok, response} <-
           Response.new(%{
             request_id: message.request_id,
             message_id: message.message_id,
             conversation_id: message.conversation_id,
             type: :error,
             payload: %{code: safe_error_code(reason), user_content: message.content}
           }) do
      broadcast_response(delivery, response)
    else
      _ -> :ok
    end
  end

  defp maybe_deliver_ingress_failure(_result, _message, _context), do: :ok

  defp actor_person(%{person: person}) when is_map(person), do: person
  defp actor_person(%{"person" => person}) when is_map(person), do: person
  defp actor_person(_actor), do: nil

  defp routing_attributes(%Context{} = context) do
    %{}
    |> maybe_put_delivery(context.delivery)
    |> maybe_put_agent(context.selected_agent_id)
  end

  defp maybe_put_delivery(attributes, %Delivery{} = delivery),
    do: Map.put(attributes, "web_delivery", Delivery.reference(delivery))

  defp maybe_put_delivery(attributes, _delivery), do: attributes

  defp maybe_put_agent(attributes, nil), do: attributes

  defp maybe_put_agent(attributes, id),
    do: Map.merge(attributes, %{"configured_agent_id" => id, "routing_source" => "bo_explicit"})

  defp delivery_channel_config_id(%Delivery{channel_config_id: id}), do: id
  defp delivery_channel_config_id(_delivery), do: nil

  defp legacy_session_id(%{consumer: :bo, topic: "chat:" <> session_id}), do: session_id
  defp legacy_session_id(_delivery), do: nil

  defp handle_command(command, %Context{consumer: :widget} = context, sink_opts, _actor) do
    operation = if command.type == :conversation_init, do: :initialize, else: :history

    request =
      widget_scope(context)
      |> Map.merge(%{
        operation: operation,
        conversation_id: command.conversation_id,
        page: history_page(command.params)
      })

    case dispatch_channel_conversations(request, context, sink_opts) do
      {:ok, messages} when is_list(messages) ->
        response(
          command,
          :conversation_history,
          command.conversation_id,
          %{
            messages: Enum.map(messages, &widget_history_message/1),
            processing: widget_processing(request, context, sink_opts)
          },
          2
        )

      {:ok, %{conversation_id: id, person_id: person_id} = details} ->
        with true <- is_integer(person_id) and person_id > 0,
             {:ok, binding} <- widget_binding(context, person_id) do
          %{
            response:
              response(command, :widget_initialized, id, Map.drop(details, [:person_id]), 2),
            delivery_binding: binding
          }
        else
          _ -> error_response(command, :missing_delivery_descriptor, 2)
        end

      {:error, reason} ->
        error_response(command, reason, 2)

      _ ->
        error_response(command, :conversation_unavailable, 2)
    end
  end

  defp handle_command(%Command{type: :conversation_init} = command, context, sink_opts, actor) do
    case resolve_conversation(command, context, sink_opts, actor) do
      {:ok, conversation, details} ->
        response(command, :conversation_initialized, conversation.id, details)

      {:error, reason} ->
        error_response(command, reason)
    end
  end

  defp handle_command(
         %Command{type: :conversation_history, conversation_id: nil} = command,
         _context,
         _sink_opts,
         _actor
       ),
       do: error_response(command, :conversation_id_required)

  defp handle_command(
         %Command{type: :conversation_history, conversation_id: conversation_id} = command,
         _context,
         sink_opts,
         actor
       ) do
    with %{id: _id} = conversation <-
           dispatch_conversation(
             %{action: :get, conversation_id: conversation_id},
             sink_opts,
             actor
           ),
         messages when is_list(messages) <-
           dispatch_conversation(
             %{action: :messages, conversation: conversation},
             sink_opts,
             actor
           ) do
      response(command, :conversation_history, conversation.id, %{
        conversation: conversation_projection(conversation),
        messages: Enum.map(messages, &message_projection/1)
      })
    else
      nil -> error_response(command, :conversation_not_found)
      {:error, reason} -> error_response(command, reason)
      _ -> error_response(command, :history_unavailable)
    end
  end

  defp widget_binding(context, person_id) do
    id = widget_scope(context).channel_config_id

    events =
      if context.delivery,
        do: Map.merge(@widget_events, context.delivery.events),
        else: @widget_events

    Delivery.new(%{
      consumer: :widget,
      channel_config_id: id,
      topic: "web_widget:recipient:#{id}:#{person_id}",
      events: events
    })
  end

  defp widget_processing(request, context, sink_opts) do
    case dispatch_channel_conversations(%{request | operation: :processing}, context, sink_opts) do
      {:ok, status} when status in [:active, :idle, :unknown] -> status
      _ -> :unknown
    end
  end

  defp widget_history_message(%{timestamp: %{value: time}} = message) do
    message
    |> Map.put(:timestamp, time)
    |> widget_history_message()
  end

  defp widget_history_message(%{role: "external"} = message), do: %{message | role: "user"}
  defp widget_history_message(message), do: message

  defp widget_scope(context) do
    %{
      channel_config_id:
        context.channel_config_id || delivery_channel_config_id(context.delivery),
      provider: "web_widget",
      sender_id: context.sender_id,
      profile_context: context.profile_context
    }
  end

  defp history_page(params) do
    Enum.reduce([:after_position, :up_to_position, :limit], [], fn key, opts ->
      case Map.get(params, key, Map.get(params, Atom.to_string(key))) do
        nil -> opts
        value -> Keyword.put(opts, key, value)
      end
    end)
  end

  defp dispatch_channel_conversations(request, context, sink_opts) do
    event_opts = [action: :channel_conversations, confidential: true]

    event =
      Event.new(request, :engine,
        actor: context.actor,
        opts: event_opts
      )

    node_router = Keyword.get(sink_opts, :node_router, NodeRouter)

    case node_router.dispatch(event) do
      %Event{response: response} -> response
      _ -> {:error, :engine_unavailable}
    end
  end

  defp resolve_conversation(%Command{conversation_id: nil}, context, sink_opts, actor),
    do: create_conversation(context, sink_opts, actor, %{})

  defp resolve_conversation(
         %Command{conversation_id: conversation_id},
         context,
         sink_opts,
         actor
       ) do
    case dispatch_conversation(
           %{action: :get, conversation_id: conversation_id},
           sink_opts,
           actor
         ) do
      %{id: _id} = conversation ->
        {:ok, conversation, %{created: false}}

      nil ->
        create_conversation(context, sink_opts, actor, %{replaced_missing_id: conversation_id})

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :conversation_unavailable}
    end
  end

  defp create_conversation(context, sink_opts, actor, details) do
    with {:ok, user_id} <- actor_user_id(context.actor),
         {:ok, %{id: _id} = conversation} <-
           dispatch_conversation(
             %{
               action: :create,
               attrs: %{
                 channel_user_id: "bo_user_#{user_id}",
                 channel_type: "bo",
                 user_id: user_id
               }
             },
             sink_opts,
             actor
           ) do
      {:ok, conversation, Map.put(details, :created, true)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :conversation_create_failed}
    end
  end

  defp dispatch_conversation(request, sink_opts, actor) do
    event = Event.new(request, :engine, actor: actor, opts: [action: :conversation])
    node_router = Keyword.get(sink_opts, :node_router, NodeRouter)

    case node_router.dispatch(event) do
      %Event{response: response} -> response
      _ -> {:error, :engine_unavailable}
    end
  end

  defp actor_user_id(%{user_id: id}) when is_integer(id) and id > 0, do: {:ok, id}
  defp actor_user_id(%{"user_id" => id}) when is_integer(id) and id > 0, do: {:ok, id}
  defp actor_user_id(_actor), do: {:error, :unauthorized}

  defp response(command, type, conversation_id, payload, version \\ 1) do
    case Response.new(%{
           protocol_version: version,
           request_id: command.request_id,
           type: type,
           conversation_id: conversation_id,
           payload: payload
         }) do
      {:ok, response} -> response
      {:error, _reason} -> error_response(command, :invalid_response_payload, version)
    end
  end

  defp error_response(command, reason, version \\ 1) do
    {:ok, response} =
      Response.new(%{
        protocol_version: version,
        request_id: command.request_id,
        type: :error,
        conversation_id: command.conversation_id,
        payload: %{code: safe_error_code(reason)}
      })

    response
  end

  defp safe_error_code(reason) when is_atom(reason), do: reason
  defp safe_error_code({reason, _details}) when is_atom(reason), do: reason
  defp safe_error_code(_reason), do: :operation_failed

  defp conversation_projection(%Conversation{} = conversation) do
    Map.take(conversation, [:id, :title, :status, :inserted_at, :updated_at])
  end

  defp message_projection(%ConversationMessage{} = message) do
    %{
      id: message.id,
      role: message.role,
      content: message.content,
      sources: message.sources,
      confidence_score: message.confidence_score,
      model: message.model,
      prompt_tokens: message.prompt_tokens,
      completion_tokens: message.completion_tokens,
      total_tokens: message.total_tokens,
      latency_ms: message.latency_ms,
      metadata: message.metadata,
      trace: message.trace,
      ratings: Enum.map(message.ratings, &rating_projection/1),
      inserted_at: message.inserted_at
    }
  end

  defp rating_projection(%MessageRating{} = rating),
    do: Map.take(rating, [:id, :rating, :reason, :comment])

  defp delivery_from_routing_context(%{attributes: attributes}) when is_map(attributes) do
    case Map.get(attributes, "web_delivery") || Map.get(attributes, :web_delivery) do
      nil -> {:ok, nil}
      reference -> Delivery.from_reference(reference)
    end
  end

  defp delivery_from_routing_context(_routing_context), do: {:ok, nil}

  defp deliver_final(%Outgoing{metadata: %{execution_disposition: "queued"}}, %Delivery{
         consumer: :widget
       }),
       do: {:ok, %{delivered: false}}

  defp deliver_final(%Outgoing{} = outgoing, %Delivery{consumer: :widget} = delivery) do
    metadata = if is_map(outgoing.metadata), do: outgoing.metadata, else: %{}
    started = Helper.present?(metadata_value(metadata, :status_message_id))
    failed = metadata_value(metadata, :error) == true

    # An execution can fail before its first status update (for example, during
    # credential resolution). Preserve its public answer as a terminal message;
    # absence of a stream does not make it a submission rejection.
    deliver_widget_answer(outgoing, delivery, started, failed)
  end

  defp deliver_final(%Outgoing{} = outgoing, %Delivery{} = delivery) do
    metadata = if is_map(outgoing.metadata), do: outgoing.metadata, else: %{}

    type =
      if metadata_value(metadata, :error) == true, do: :message_failed, else: :message_complete

    with {:ok, response} <-
           Response.new(%{
             request_id: metadata_value(metadata, :request_id),
             message_id: outgoing.in_reply_to || metadata_value(metadata, :message_id),
             conversation_id: metadata_value(metadata, :conversation_id),
             type: type,
             payload: final_payload(outgoing, metadata, delivery.consumer)
           }),
         :ok <- broadcast_response(delivery, response) do
      receipt =
        if delivery.consumer == :widget,
          do: %{
            delivered: true,
            confirmation: :confirmed,
            message_id: metadata_value(metadata, :assistant_message_id)
          },
          else: %{delivered: true}

      {:ok, receipt}
    end
  end

  defp deliver_widget_answer(outgoing, delivery, started, failed) do
    request_id = metadata_value(outgoing.metadata, :request_id)
    type = if failed, do: :message_failed, else: :message_complete

    with :ok <- ensure_widget_message(delivery, request_id, started),
         :ok <- widget_event(delivery, request_id, :typing, %{active: false}),
         :ok <-
           widget_event(
             delivery,
             request_id,
             type,
             final_payload(outgoing, outgoing.metadata, :widget)
           ) do
      {:ok,
       %{
         delivered: true,
         confirmation: :confirmed,
         message_id: metadata_value(outgoing.metadata, :assistant_message_id)
       }}
    end
  end

  defp ensure_widget_message(_delivery, _request_id, true), do: :ok

  defp ensure_widget_message(delivery, request_id, false) do
    with :ok <- widget_event(delivery, request_id, :typing, %{active: true}) do
      widget_event(delivery, request_id, :message_create, %{body: ""})
    end
  end

  defp deliver_status(request, %Delivery{consumer: :widget} = delivery) do
    stage = status_stage(Map.get(request, :intent_meta))
    request_id = Map.get(request, :request_id)
    started = Helper.present?(Map.get(request, :message_id))

    with :ok <- widget_status(request, delivery, request_id, stage, started) do
      message_id = if stage == :execution_started or started, do: delivery.message_id

      {:ok,
       %{
         action: :updated,
         message_id: message_id,
         update_intent: Map.get(request, :update_intent)
       }}
    end
  end

  defp deliver_status(request, %Delivery{} = delivery) do
    request_id = Map.get(request, :request_id)
    body = Map.get(request, :body)

    if Helper.present?(request_id) and Helper.present?(body) do
      do_deliver_status(request, request_id, body, delivery)
    else
      {:ok, %{action: :noop, message_id: nil, update_intent: Map.get(request, :update_intent)}}
    end
  end

  defp widget_status(_request, delivery, request_id, :execution_started, _started),
    do: ensure_widget_message(delivery, request_id, false)

  defp widget_status(_request, delivery, request_id, :submission_accepted, _started),
    do: widget_event(delivery, request_id, :status, %{accepted: true, created: false}, nil)

  defp widget_status(_request, delivery, request_id, :submission_rejected, _started),
    do: widget_event(delivery, request_id, :error, %{code: :submission_rejected}, nil)

  defp widget_status(_request, delivery, request_id, :failed, true) do
    with :ok <- widget_event(delivery, request_id, :typing, %{active: false}) do
      widget_event(delivery, request_id, :message_failed, %{
        body: "Unable to save the response",
        error: true
      })
    end
  end

  defp widget_status(_request, delivery, request_id, :failed, false),
    do: widget_event(delivery, request_id, :error, %{code: :persistence_failed}, nil)

  defp widget_status(
         %{update_intent: :stream_delta, body: body},
         delivery,
         request_id,
         _stage,
         true
       ),
       do: widget_event(delivery, request_id, :message_edit, %{body: body})

  defp widget_status(_request, delivery, request_id, stage, true) do
    widget_event(delivery, request_id, :message_step, %{
      kind: :activity,
      state: :running,
      step_id: "activity:#{stage}",
      label: activity_label(stage)
    })
  end

  defp widget_status(_request, _delivery, _request_id, _stage, false), do: :ok

  defp activity_label(:retrieving), do: "Retrieving information"
  defp activity_label(:answering), do: "Preparing answer"
  defp activity_label(_stage), do: "Working"

  defp widget_event(delivery, request_id, type, payload),
    do: widget_event(delivery, request_id, type, payload, delivery.message_id)

  defp widget_event(delivery, request_id, type, payload, message_id) do
    with {:ok, response} <-
           Response.new(%{
             protocol_version: 2,
             request_id: request_id,
             conversation_id: delivery.conversation_id,
             message_id: message_id,
             type: type,
             payload: payload
           }) do
      broadcast_response(delivery, response)
    end
  end

  defp do_deliver_status(request, request_id, body, delivery) do
    update_intent = Map.get(request, :update_intent)
    type = if update_intent == :stream_delta, do: :message_edit, else: :status
    message_id = Map.get(request, :message_id) || request_id

    with {:ok, response} <-
           Response.new(%{
             request_id: request_id,
             message_id: message_id,
             type: type,
             payload: %{
               body: body,
               stage: status_stage(Map.get(request, :intent_meta)),
               update_intent: update_intent
             }
           }),
         :ok <- broadcast_response(delivery, response) do
      action = if Helper.present?(Map.get(request, :message_id)), do: :updated, else: :created
      {:ok, %{action: action, message_id: message_id, update_intent: update_intent}}
    end
  end

  defp broadcast_response(%Delivery{} = delivery, %Response{} = response) do
    with {:ok, event_name} <- response_event(delivery, response) do
      Phoenix.PubSub.broadcast(
        Zaq.PubSub,
        delivery.topic,
        {:web_response, event_name, response}
      )
    end
  end

  defp response_event(%Delivery{consumer: :widget} = delivery, %Response{
         type: :status,
         payload: %{accepted: true}
       }) do
    case Delivery.event_name(delivery, :status) do
      {:ok, _} = event -> event
      _ -> {:ok, "response.status"}
    end
  end

  defp response_event(delivery, response), do: Delivery.event_name(delivery, response.type)

  defp final_payload(outgoing, metadata, :widget) do
    %{
      body: outgoing.body,
      error: metadata_value(metadata, :error) == true,
      assistant_message_id: metadata_value(metadata, :assistant_message_id),
      user_message_id: metadata_value(metadata, :user_message_id)
    }
  end

  defp final_payload(outgoing, metadata, :bo) do
    %{
      body: outgoing.body,
      user_content: metadata_value(metadata, :user_content),
      sources: metadata_value(metadata, :sources) || [],
      confidence_score: metadata_value(metadata, :confidence_score),
      error: metadata_value(metadata, :error) == true,
      error_type: metadata_value(metadata, :error_type),
      assistant_message_id: metadata_value(metadata, :assistant_message_id),
      user_message_id: metadata_value(metadata, :user_message_id),
      agent: metadata_value(metadata, :agent),
      model: metadata_value(metadata, :model),
      latency_ms: metadata_value(metadata, :latency_ms),
      measurements: metadata_value(metadata, :measurements) || %{},
      prompt_tokens: metadata_value(metadata, :prompt_tokens),
      completion_tokens: metadata_value(metadata, :completion_tokens),
      total_tokens: metadata_value(metadata, :total_tokens),
      trace: metadata_value(metadata, :trace) || [],
      tool_calls: metadata_value(metadata, :tool_calls) || []
    }
  end

  defp metadata_value(metadata, key),
    do: Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
end
