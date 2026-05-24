defmodule ZaqWeb.Live.BO.System.SystemConfig.ImageToTextEventsTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias ZaqWeb.Live.BO.System.SystemConfig.ImageToTextEvents

  test "apply_save_error/2 assigns image-to-text form" do
    socket = %Socket{assigns: %{__changed__: %{}}}
    changeset = %Ecto.Changeset{action: :validate}

    updated = ImageToTextEvents.apply_save_error(socket, changeset)

    assert %Phoenix.HTML.Form{} = updated.assigns.image_to_text_form
  end
end
