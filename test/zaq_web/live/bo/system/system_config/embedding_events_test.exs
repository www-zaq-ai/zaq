defmodule ZaqWeb.Live.BO.System.SystemConfig.EmbeddingEventsTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias ZaqWeb.Live.BO.System.SystemConfig.EmbeddingEvents

  test "maybe_open_save_confirm/2 returns confirm branch when model changed" do
    socket = %Socket{assigns: %{__changed__: %{}, model_changed: true}}

    assert {:confirm, updated} =
             EmbeddingEvents.maybe_open_save_confirm(socket, %{"model" => "m1"})

    assert updated.assigns.embedding_save_confirm_modal
    assert updated.assigns.pending_embedding_params == %{"model" => "m1"}
  end

  test "unlock/2 unlocks and reloads credential options" do
    socket = %Socket{assigns: %{__changed__: %{}}}
    updated = EmbeddingEvents.unlock(socket, fn -> [{"cred", "1"}] end)

    refute updated.assigns.embedding_unlock_modal
    refute updated.assigns.embedding_locked
    assert updated.assigns.embedding_credential_options == [{"cred", "1"}]
  end
end
