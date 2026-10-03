defmodule ZaqWeb.Live.BO.Communication.IngressStatusAggregateTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ZaqWeb.Live.BO.Communication.IngressStatusUI

  property "provider health is order-independent and includes every connector" do
    check all(statuses <- list_of(member_of([:ok, :pending, :error]), min_length: 1)) do
      connectors =
        statuses
        |> Enum.with_index()
        |> Enum.map(fn {status, id} ->
          %{id: id, name: "Config #{id}", status: %{status: status}}
        end)

      result = IngressStatusUI.aggregate(connectors)
      assert result.connectors == connectors
      assert result.status == IngressStatusUI.aggregate(Enum.reverse(connectors)).status

      cond do
        Enum.all?(statuses, &(&1 == :ok)) -> assert result.status == :ok
        Enum.all?(statuses, &(&1 == :error)) -> assert result.status == :error
        true -> assert result.status == :pending
      end
    end
  end
end
