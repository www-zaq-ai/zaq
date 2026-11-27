defmodule Zaq.Engine.Extension.ActionProtocol do
  @moduledoc false

  alias Zaq.Engine.Extension.Invocation
  alias Zaq.Engine.Extension.Rpc.Gateway.V1.{ActionLimits, ActionRequest, GatewayHello}

  @fields ~w(max_concurrent max_unreceipted_replies max_unreceipted_bytes max_timeout_ms max_json_depth max_reply_envelope_bytes receipt_timeout_ms)a
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  @doc "Returns ZAQ's supported Action limits within the transport envelope ceiling."
  @spec offer(pos_integer()) :: ActionLimits.t()
  def offer(envelope_bytes) do
    %ActionLimits{
      max_concurrent: 8,
      max_unreceipted_replies: 32,
      max_unreceipted_bytes: 67_108_864,
      max_timeout_ms: 60_000,
      max_json_depth: 32,
      max_reply_envelope_bytes: min(8_388_608, envelope_bytes),
      receipt_timeout_ms: 60_000
    }
  end

  @doc "Accepts health-only peers, but rejects an inconsistent selected Action capability."
  @spec negotiate(GatewayHello.t(), pos_integer()) ::
          {:ok, ActionLimits.t() | nil} | {:error, atom()}
  def negotiate(%GatewayHello{} = hello, envelope_bytes) do
    if "actions.v1" in hello.capabilities do
      validate_limits(hello.action_limits, offer(envelope_bytes))
    else
      {:ok, nil}
    end
  end

  defp validate_limits(%ActionLimits{} = selected, offered) do
    within_offer = Enum.all?(@fields, &(Map.fetch!(selected, &1) in 1..Map.fetch!(offered, &1)))

    if within_offer and selected.max_unreceipted_replies >= 2 and
         selected.max_reply_envelope_bytes >= 512 and
         selected.max_unreceipted_bytes >= selected.max_reply_envelope_bytes + 512 and
         selected.receipt_timeout_ms >= 1_000 do
      {:ok, selected}
    else
      {:error, :invalid_envelope}
    end
  end

  defp validate_limits(_, _), do: {:error, :invalid_envelope}

  @doc "Validates canonical, globally fresh UUIDv4 wire identifiers without creating atoms."
  @spec valid_id?(String.t()) :: boolean()
  def valid_id?(id), do: is_binary(id) and byte_size(id) == 36 and Regex.match?(@uuid, id)

  @doc "Maps a known request variant to the internal Engine operation; no wire execution context is accepted."
  @spec invocation(ActionRequest.t(), ActionLimits.t()) ::
          {:ok, Invocation.t(), :SYNC | :ASYNC} | {:error, atom()}
  def invocation(%ActionRequest{timeout_ms: timeout} = request, limits) do
    if timeout in 1..limits.max_timeout_ms do
      operation(request.operation, limits)
    else
      {:error, :INVALID_ARGUMENT}
    end
  end

  defp operation({:list, list}, _depth),
    do:
      {:ok, %Invocation{operation: :list, page_size: list.page_size, page_token: list.page_token},
       :SYNC}

  defp operation({:describe, describe}, limits),
    do:
      {:ok,
       %Invocation{
         operation: :describe,
         key: describe.key,
         max_json_depth: limits.max_json_depth,
         max_result_bytes: limits.max_reply_envelope_bytes
       }, :SYNC}

  defp operation({:execute, %{mode: mode} = execute}, limits) when mode in [:SYNC, :ASYNC],
    do:
      {:ok,
       %Invocation{
         operation: :execute,
         key: execute.key,
         arguments_json: execute.arguments_json,
         max_json_depth: limits.max_json_depth,
         max_result_bytes: limits.max_reply_envelope_bytes
       }, mode}

  defp operation({:execute, _}, _depth), do: {:error, :INVALID_ARGUMENT}
  defp operation(_, _depth), do: {:error, :unsupported_operation}
end
