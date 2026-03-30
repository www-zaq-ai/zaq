defmodule ZaqWeb.Live.BO.Communication.ServiceGate do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias ZaqWeb.Components.ServiceUnavailable

  @spec on_mount([atom()], map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(required_roles, _params, _session, socket) when is_list(required_roles) do
    available = ServiceUnavailable.available?(required_roles)

    {:cont,
     socket
     |> assign(:service_available, available)
     |> assign(:required_roles, required_roles)}
  end
end
