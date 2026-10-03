defmodule Zaq.Channels.EmailBridge.SelfAddresses do
  @moduledoc "Email-boundary self-address exclusion shared by delivery and recipient discovery."

  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Messages.Incoming.Audience
  alias Zaq.Engine.Messages.ReplyTargets

  @doc "Normalizes and deduplicates addresses, excluding the supplied connector-local self addresses."
  def exclude(addresses, own) do
    own = Enum.map(own, &normalize/1)
    addresses |> Enum.map(&normalize/1) |> Enum.uniq() |> Kernel.--([nil | own])
  end

  @doc "Filters discovery and reply destinations while preserving sender and delivery metadata."
  def filter_incoming(%Incoming{} = incoming, own) do
    context = incoming.routing_context

    audience =
      case context.audience do
        %Audience{} = audience ->
          recipients = exclude(audience.recipients, own)

          participants =
            Enum.reject(audience.participants, &(exclude([&1.identifier], own) == []))

          %{audience | recipients: recipients, participants: participants}

        other ->
          other
      end

    targets =
      case context.reply_targets do
        %ReplyTargets{} = targets ->
          to = exclude(targets.to, own)
          %{targets | to: to, cc: exclude(targets.cc, own ++ to)}

        other ->
          other
      end

    %{incoming | routing_context: %{context | audience: audience, reply_targets: targets}}
  end

  defp normalize(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      address -> address
    end
  end

  defp normalize(_), do: nil
end
