defmodule ZaqWeb.Live.BO.System.PortalConnectPasswordLive do
  @moduledoc """
  Provides live password guidance for the Portal connect form. Submission and
  setup authorization stay with `ZaqWeb.PortalConnectController`.
  """

  use ZaqWeb, :live_view

  alias Zaq.Accounts.PasswordPolicy
  alias ZaqWeb.Components.DesignSystem.{Button, SecretInput}
  alias ZaqWeb.Components.PasswordPolicyComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :requirements, PasswordPolicy.requirements_with_status("")),
     layout: false}
  end

  @impl true
  def handle_event("validate_password", %{"password" => password}, socket)
      when is_binary(password) do
    {:noreply, assign(socket, :requirements, PasswordPolicy.requirements_with_status(password))}
  end

  def handle_event("validate_password", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <.form for={%{}} action={~p"/bo/connect"} class="zaq-layout-stack">
      <SecretInput.secret_input
        id="password"
        name="password"
        label="New Password"
        autocomplete="new-password"
        aria-describedby="portal-password-requirements"
        phx-change="validate_password"
        phx-debounce="150"
        required
      />
      <div aria-live="polite">
        <PasswordPolicyComponents.password_requirements
          id="portal-password-requirements"
          requirements={@requirements}
        />
      </div>
      <SecretInput.secret_input
        id="password-confirmation"
        name="password_confirmation"
        label="Confirm Password"
        autocomplete="new-password"
        required
      />
      <Button.button type="submit" variant={:primary} class="w-full">Connect Portal</Button.button>
    </.form>
    """
  end
end
