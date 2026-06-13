defmodule ZaqWeb.Live.BO.WorkflowGuardTest do
  use ZaqWeb.ConnCase

  alias ZaqWeb.Live.BO.WorkflowGuard

  defp build_socket do
    %Phoenix.LiveView.Socket{
      view: ZaqWeb.Live.BO.WorkflowGuard,
      private: %{
        live_temp: %{},
        lifecycle: %Phoenix.LiveView.Lifecycle{}
      }
    }
  end

  describe "on_mount/4 — :require_workflows" do
    test "halts and redirects to dashboard when config is absent (fail-closed default)" do
      Application.delete_env(:zaq, :workflows_enabled)

      try do
        assert {:halt, socket} =
                 WorkflowGuard.on_mount(:require_workflows, %{}, %{}, build_socket())

        assert socket.redirected != nil
      after
        Application.put_env(:zaq, :workflows_enabled, true)
      end
    end

    test "halts and redirects to dashboard when workflows_enabled is false" do
      Application.put_env(:zaq, :workflows_enabled, false)

      try do
        assert {:halt, socket} =
                 WorkflowGuard.on_mount(:require_workflows, %{}, %{}, build_socket())

        assert socket.redirected != nil
      after
        Application.put_env(:zaq, :workflows_enabled, true)
      end
    end

    test "continues when workflows_enabled is true" do
      Application.put_env(:zaq, :workflows_enabled, true)

      assert {:cont, _socket} =
               WorkflowGuard.on_mount(:require_workflows, %{}, %{}, build_socket())
    end
  end
end
