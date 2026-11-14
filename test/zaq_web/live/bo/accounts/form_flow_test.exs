defmodule ZaqWeb.Live.BO.Accounts.FormFlowTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias ZaqWeb.Live.BO.Accounts.FormFlow

  test "unexpected save error shows a generic flash without navigating" do
    socket = %Socket{assigns: %{__changed__: %{}, flash: %{}}}

    assert {:noreply, updated} =
             FormFlow.handle_save_result(socket, {:error, :conflict},
               success_message: "Role created.",
               to: "/bo/roles"
             )

    assert Phoenix.Flash.get(updated.assigns.flash, :error) ==
             "The account change could not be saved."

    assert updated.redirected == nil
  end
end
