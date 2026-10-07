defmodule Zaq.Channels.Web.Runtime do
  @moduledoc """
  Host construction hook for adapter-owned widget runtimes.

  The configured server module builds child specs using the shared contracts and
  a fixed sink. ZAQ owns no widget endpoint; the adapter owns authentication,
  embedding/origin enforcement and subscription authorization. Payloads cannot
  select a builder, override widget ID or replace the configuration-bound sink.
  """

  alias Zaq.Channels.Web.{Command, Context, Delivery, Message, Response}
  alias Zaq.ConnectorConfig.WidgetSettings
  alias Zaq.Event
  alias Zaq.NodeRouter

  @doc "Builds adapter-owned specs from server configuration, without a package dependency."
  def build(%{provider: provider, id: id} = config)
      when provider in [:web_widget, "web_widget"] do
    definition = Application.get_env(:zaq, :channels, %{}) |> Map.get(:web_widget, %{})
    adapter = Map.get(definition, :adapter)
    settings = Map.get(config, :settings, %{}) || %{}

    hooks = %{
      widget_id: id,
      allowed_domains: Map.get(settings, "allowed_domains", []),
      display_name: Map.get(settings, "display_name", Map.get(config, :name)),
      message: Message,
      command: Command,
      context: Context,
      delivery: Delivery,
      response: Response,
      sink_mfa: {__MODULE__, :from_listener, [%{id: id}]}
    }

    if validate_settings(settings) == :ok and is_integer(id) and id > 0 and
         is_atom(adapter) and not is_nil(adapter) and Code.ensure_loaded?(adapter) and
         function_exported?(adapter, :build, 2) do
      normalize_specs(adapter.build(config, hooks))
    else
      {:error, :widget_runtime_not_configured}
    end
  rescue
    _error -> {:error, :widget_runtime_construction_failed}
  end

  def build(_config), do: {:ok, {nil, []}}

  @doc "Asks the trusted server adapter for copyable installation text; never executes markup."
  @spec embed_script(term(), term(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def embed_script(id, base_url, opts \\ [])

  def embed_script(id, base_url, opts)
      when is_integer(id) and id > 0 and is_binary(base_url) and byte_size(base_url) > 0 do
    definition = Zaq.Config.get(:zaq, :channels, %{}, opts) |> Map.get(:web_widget, %{})
    adapter = Map.get(definition, :adapter)

    if supports_callback?(adapter, :embed_script) do
      normalize_snippet(adapter.embed_script(id, base_url))
    else
      {:error, :widget_embed_not_configured}
    end
  rescue
    _error -> {:error, :widget_embed_failed}
  catch
    _kind, _reason -> {:error, :widget_embed_failed}
  end

  def embed_script(_id, _base_url, _opts), do: {:error, :invalid_widget_embed_request}

  @doc "Returns adapter readiness and a secret-free live runtime status."
  def status(id, opts \\ []) do
    definition = Zaq.Config.get(:zaq, :channels, %{}, opts) |> Map.get(:web_widget, %{})
    adapter = Map.get(definition, :adapter)

    {:ok,
     %{
       available?:
         supports_callback?(adapter, :build) and supports_callback?(adapter, :embed_script),
       runtime: runtime_status(id)
     }}
  end

  defp runtime_status(id) when is_integer(id) and id > 0 do
    case Zaq.Channels.Supervisor.lookup_runtime("web_widget_#{id}") do
      {:ok, _} -> :running
      _ -> :not_running
    end
  end

  defp runtime_status(_id), do: :not_running

  defp supports_callback?(adapter, callback) do
    is_atom(adapter) and not is_nil(adapter) and Code.ensure_loaded?(adapter) and
      function_exported?(adapter, callback, 2)
  end

  defp normalize_snippet({:ok, snippet})
       when is_binary(snippet) and byte_size(snippet) in 1..32_768 do
    if String.valid?(snippet), do: {:ok, snippet}, else: {:error, :invalid_widget_embed_script}
  end

  defp normalize_snippet({:error, _reason}), do: {:error, :widget_embed_failed}
  defp normalize_snippet(_result), do: {:error, :invalid_widget_embed_script}

  @doc "Validates persisted widget presentation/embedding inputs; endpoint enforcement is adapter-owned."
  defdelegate validate_settings(settings), to: WidgetSettings, as: :validate

  defp normalize_specs({:ok, {state, listeners}})
       when (is_nil(state) or is_map(state)) and is_list(listeners),
       do: {:ok, {state, listeners}}

  defp normalize_specs({:error, _} = error), do: error
  defp normalize_specs(_result), do: {:error, :invalid_widget_runtime_specs}

  @doc "Receives only normalized shared payloads and adapter-verified, config-bound Context."
  def from_listener(%{id: id}, payload, opts) when is_list(opts) do
    case Keyword.get(opts, :context) do
      %Context{consumer: :widget, channel_config_id: ^id} = context -> dispatch(payload, context)
      _ -> {:error, :unauthorized}
    end
  end

  def from_listener(_config, _payload, _opts), do: {:error, :unauthorized}

  defp dispatch(payload, context)
       when is_struct(payload, Message) or is_struct(payload, Command) do
    Event.new(%{payload: payload, context: context}, :channels, opts: [action: :web_ingress])
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end

  defp dispatch(_payload, _context), do: {:error, :invalid_payload}
end
