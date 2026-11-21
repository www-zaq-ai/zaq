defmodule Zaq.Engine.Extension.Actions do
  @moduledoc """
  Translates Extension operations through Registry and the validated Action contract.
  This is a transport consumer, not an Action catalog or alternate execution engine.
  """

  alias Jido.Action.Schema
  alias Zaq.Agent.Tools.{ActionContract, Registry}
  alias Zaq.Engine.Extension.{ActionJson, Invocation}

  alias Zaq.Engine.Extension.Rpc.Gateway.V1.{
    ActionDescription,
    ActionFailure,
    ActionList,
    ActionMetadata
  }

  alias Zaq.{Event, NodeRouter}

  @doc "Executes the confidential Engine hop and returns completion through a synchronous Event hop."
  @spec handle_event(Event.t()) :: Event.t()
  def handle_event(%Event{request: %Invocation{} = invocation, opts: opts} = event) do
    if opts[:confidential] == true do
      invocation
      |> execute()
      |> Event.new(:engine,
        trace_id: event.trace_id,
        assigns: event.assigns,
        opts: [action: :extension_action_completed, confidential: true]
      )
      |> NodeRouter.dispatch()

      %{event | response: :ok}
    else
      %{event | response: {:error, :confidential_event_required}}
    end
  end

  @doc "Delivers a completion only to the runtime incarnation recorded by ZAQ at admission."
  @spec deliver_completion(Event.t()) :: Event.t()
  def deliver_completion(%Event{assigns: assigns, opts: opts} = event) do
    with true <- opts[:confidential] == true,
         %{extension_owner: owner, extension_generation: generation}
         when is_pid(owner) and is_reference(generation) <- assigns do
      send(owner, {:extension_action_completed, generation, event.trace_id, event.request})
      %{event | response: :ok}
    else
      _ -> %{event | response: {:error, :invalid_completion}}
    end
  end

  @doc "Executes an admitted operation with ZAQ-owned service permissions and safe failure messages."
  @spec execute(Invocation.t()) :: {atom(), term()}
  def execute(%Invocation{} = invocation) do
    original_level = Logger.get_process_level(self())
    Logger.put_process_level(self(), :none)

    try do
      perform(invocation)
    rescue
      _ -> failure(:INTERNAL, invocation.operation == :execute)
    catch
      _, _ -> failure(:INTERNAL, invocation.operation == :execute)
    after
      if original_level,
        do: Logger.put_process_level(self(), original_level),
        else: Logger.delete_process_level(self())
    end
  end

  @doc false
  @spec failure(atom(), boolean()) :: {:failure, ActionFailure.t()}
  def failure(code, effects_may_have_occurred \\ false) do
    {:failure, %ActionFailure{code: code, effects_may_have_occurred: effects_may_have_occurred}}
  end

  defp perform(%Invocation{operation: :list} = invocation) do
    size = if invocation.page_size == 0, do: 50, else: invocation.page_size

    if size in 1..100 and byte_size(invocation.page_token) <= 256 and
         String.valid?(invocation.page_token) do
      entries =
        Registry.tools()
        |> Enum.sort_by(& &1.key)
        |> Enum.filter(&(&1.key > invocation.page_token))

      page = Enum.take(entries, size)
      token = if length(entries) > size, do: List.last(page).key, else: ""
      {:listed, %ActionList{actions: Enum.map(page, &metadata/1), next_page_token: token}}
    else
      failure(:INVALID_ARGUMENT)
    end
  end

  defp perform(%Invocation{operation: :describe, key: key} = invocation) do
    with {:ok, descriptor} <- lookup(key),
         {:ok, input} <- export_schema(descriptor.module.schema(), invocation),
         {:ok, output} <- output_schema(descriptor.module, invocation) do
      {:described,
       %ActionDescription{
         metadata: metadata(descriptor),
         input_schema_json: input,
         output_schema_json: output
       }}
    else
      :unknown -> failure(:UNKNOWN_ACTION)
      {:error, :too_large} -> failure(:RESULT_TOO_LARGE)
      :error -> failure(:RESULT_NOT_SERIALIZABLE)
      _ -> failure(:INTERNAL)
    end
  end

  defp perform(%Invocation{operation: :execute} = invocation) do
    with {:ok, descriptor} <- lookup(invocation.key),
         {:ok, params} <-
           ActionJson.decode_object(invocation.arguments_json, invocation.max_json_depth),
         {:ok, _validated} <- ActionContract.validate(descriptor.module, params) do
      execute_action(descriptor.module, params, invocation)
    else
      :unknown -> failure(:UNKNOWN_ACTION)
      _ -> failure(:INVALID_ARGUMENT)
    end
  end

  defp execute_action(module, params, invocation) do
    context = %{skip_permissions: true, event_opts: [confidential: true], extension: true}

    # The stream owns waiting deadlines; Jido must not kill a timed-out side effect.
    case ActionContract.execute(module, params, context,
           max_retries: 0,
           timeout: 0,
           telemetry: :silent
         ) do
      {:ok, value} ->
        case ActionJson.encode(value, invocation.max_json_depth, invocation.max_result_bytes) do
          {:ok, json} -> {:result_json, json}
          {:error, :too_large} -> failure(:RESULT_TOO_LARGE, true)
          :error -> failure(:RESULT_NOT_SERIALIZABLE, true)
        end

      _ ->
        failure(:ACTION_FAILED, true)
    end
  end

  defp output_schema(module, invocation) do
    if function_exported?(module, :output_schema, 0) do
      case module.output_schema() do
        schema when schema in [nil, []] -> {:ok, nil}
        schema -> export_schema(schema, invocation)
      end
    else
      {:ok, nil}
    end
  end

  defp lookup(key) do
    case Registry.resolve_modules([key]) do
      {:ok, [module]} ->
        Code.ensure_loaded!(module)
        {:ok, Enum.find(Registry.tools(), &(&1.key == key))}

      _ ->
        :unknown
    end
  end

  defp metadata(descriptor) do
    version =
      if function_exported?(descriptor.module, :vsn, 0) do
        case descriptor.module.vsn() do
          value when is_binary(value) -> value
          _ -> nil
        end
      end

    %ActionMetadata{
      key: descriptor.key,
      name: descriptor.label,
      description: descriptor.description,
      version: version
    }
  end

  defp export_schema(schema, invocation),
    do:
      schema
      |> Schema.to_json_schema()
      |> ActionJson.encode(invocation.max_json_depth, invocation.max_result_bytes)
end
