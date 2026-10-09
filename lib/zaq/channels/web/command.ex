defmodule Zaq.Channels.Web.Command do
  @moduledoc """
  Closed web transport command envelope for operations that are not messages.

  Version 1 supports conversation initialization and bounded history requests.
  Commands carry no executable module/function/action selection and no trusted
  actor, capability or delivery context.
  """

  alias Zaq.Channels.Web.{Stylesheet, Validation}

  @allowed_fields [:request_id, :type, :conversation_id, :params]
  @forbidden_params [:action, :actor, :delivery, :function, :mfa, :module, :skip_permissions]

  @enforce_keys [:request_id, :type]
  defstruct @enforce_keys ++ [:conversation_id, params: %{}]

  @type command_type :: :conversation_init | :conversation_history
  @type t :: %__MODULE__{
          request_id: String.t(),
          type: command_type(),
          conversation_id: String.t() | nil,
          params: map()
        }

  @doc "Builds a supported non-message web command."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- Validation.reject_unknown_fields(attrs, @allowed_fields),
         {:ok, request_id} <-
           Validation.identifier(Validation.fetch(attrs, :request_id), :request_id,
             required: true
           ),
         {:ok, type} <- type(Validation.fetch(attrs, :type)),
         {:ok, conversation_id} <-
           Validation.identifier(Validation.fetch(attrs, :conversation_id), :conversation_id),
         {:ok, params} <- Validation.map(Validation.fetch(attrs, :params), :params),
         :ok <- Validation.forbidden_keys(params, @forbidden_params, :forbidden_params),
         :ok <- validate_stylesheet(type, params) do
      {:ok,
       %__MODULE__{
         request_id: request_id,
         type: type,
         conversation_id: conversation_id,
         params: params
       }}
    end
  end

  def new(_attrs), do: {:error, {:invalid_field, :command}}

  defp validate_stylesheet(type, params) do
    Enum.reduce_while([:stylesheet_url, "stylesheet_url"], :ok, fn key, :ok ->
      case validate_style_param(type, Map.fetch(params, key)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_style_param(_type, :error), do: :ok

  defp validate_style_param(:conversation_init, {:ok, value}), do: Stylesheet.validate(value)

  defp validate_style_param(_type, {:ok, _value}),
    do: {:error, {:invalid_field, :stylesheet_url}}

  defp type(type) when type in [:conversation_init, "conversation.init"],
    do: {:ok, :conversation_init}

  defp type(type) when type in [:conversation_history, "conversation.history.request"],
    do: {:ok, :conversation_history}

  defp type(_type), do: {:error, {:invalid_field, :type}}
end
