defmodule ZaqWeb.Live.BO.Communication.IngressStatusUITest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Live.BO.Communication.IngressStatusUI

  describe "color/1" do
    test "returns success class for string ok status" do
      assert IngressStatusUI.color(%{"status" => "ok"}) == "status-success"
      assert IngressStatusUI.color(%{status: "ok"}) == "status-success"
    end

    test "returns error class for string error status" do
      assert IngressStatusUI.color(%{"status" => "error"}) == "status-error"
    end

    test "returns neutral class for unknown or missing status" do
      assert IngressStatusUI.color(%{"status" => "degraded"}) == "status-neutral"
      assert IngressStatusUI.color(%{}) == "status-neutral"
      assert IngressStatusUI.color(nil) == "status-neutral"
    end
  end

  describe "normalize_response/1" do
    test "returns status map unchanged for {:ok, map}" do
      status = %{status: :ok, mode: "http", summary: "Healthy"}

      assert IngressStatusUI.normalize_response({:ok, status}) == status
    end

    test "wraps {:error, reason} into standardized error payload" do
      reason = :timeout

      assert IngressStatusUI.normalize_response({:error, reason}) == %{
               status: :error,
               mode: "unknown",
               summary: "Status check failed",
               reason: reason
             }
    end

    test "wraps unexpected response into standardized error payload" do
      other = %{unexpected: true}

      assert IngressStatusUI.normalize_response(other) == %{
               status: :error,
               mode: "unknown",
               summary: "Unexpected status response",
               reason: other
             }
    end
  end

  describe "apply_async_result/2" do
    test "sets statuses and clears loading for successful async map result" do
      socket =
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(:ingress_statuses, %{old: :value})
        |> Phoenix.Component.assign(:ingress_status_loading, %{mattermost: true})

      statuses = %{mattermost: %{status: :ok}}

      updated = IngressStatusUI.apply_async_result(socket, {:ok, statuses})

      assert updated.assigns.ingress_statuses == statuses
      assert updated.assigns.ingress_status_loading == %{}
    end

    test "clears statuses and loading for failed async result" do
      socket =
        %Phoenix.LiveView.Socket{}
        |> Phoenix.Component.assign(:ingress_statuses, %{mattermost: %{status: :ok}})
        |> Phoenix.Component.assign(:ingress_status_loading, %{mattermost: true})

      updated = IngressStatusUI.apply_async_result(socket, {:error, :timeout})

      assert updated.assigns.ingress_statuses == %{}
      assert updated.assigns.ingress_status_loading == %{}
    end
  end
end
