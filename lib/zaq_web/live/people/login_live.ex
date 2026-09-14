defmodule ZaqWeb.Live.People.LoginLive do
  @moduledoc "Presentational People sign-in screen; credential operations use CSRF-protected HTTP forms."
  use ZaqWeb, :live_view

  alias ZaqWeb.Components.DesignSystem.{Button, Input}
  alias ZaqWeb.Components.PersonLayout

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     assign(socket,
       page_title: "Sign in",
       challenge: session["person_login_challenge"],
       resend_available_at: get_in(session, ["person_login_challenge", :resend_available_at]),
       email_form: to_form(%{"email" => session["person_login_email"] || ""}),
       code_form: to_form(%{}),
       resend_form: to_form(%{})
     )}
  end

  @impl true
  def render(assigns) do
    remaining =
      if assigns.resend_available_at,
        do: max(0, DateTime.diff(assigns.resend_available_at, DateTime.utc_now(:second))),
        else: 0

    assigns = assign(assigns, :resend_seconds, remaining)

    ~H"""
    <PersonLayout.person_layout flash={@flash}>
      <section class="zaq-card-default zaq-layout-stack">
        <h1 class="zaq-text-h1">Sign in to ZAQ</h1>
        <%= if @challenge do %>
          <p class="zaq-text-body">
            Enter the eight-digit code sent to your configured communication channel.
          </p>
          <div
            id="people-otp"
            phx-hook="PeopleOTP"
            data-expires-at={@challenge.expires_at && DateTime.to_iso8601(@challenge.expires_at)}
            data-resend-available-at={
              @resend_available_at && DateTime.to_iso8601(@resend_available_at)
            }
          >
            <.form
              for={@code_form}
              id="people-code-form"
              action="/people/session"
              class="zaq-layout-stack"
            >
              <Input.input type="hidden" name="challenge_id" value={@challenge.challenge_id} />
              <div id="people-code-row" class="zaq-people-code-row">
                <Input.input
                  id="people-code"
                  field={@code_form[:code]}
                  label="One-time code"
                  type="text"
                  inputmode="numeric"
                  autocomplete="one-time-code"
                  required
                  placeholder="1234-5678"
                  aria-describedby="people-code-timer"
                />
                <Button.button
                  id="people-resend"
                  type="submit"
                  form="people-resend-form"
                  variant={:secondary}
                  aria-label="Resend code"
                  aria-describedby="people-resend-caption"
                  disabled={@resend_seconds > 0}
                >
                  <span id="people-resend-caption" data-resend-countdown phx-update="ignore">
                    <%= if @resend_seconds > 0 do %>
                      Resend in {div(@resend_seconds, 60)
                      |> Integer.to_string()
                      |> String.pad_leading(2, "0")}:{rem(@resend_seconds, 60)
                      |> Integer.to_string()
                      |> String.pad_leading(2, "0")}
                    <% else %>
                      Resend code
                    <% end %>
                  </span>
                </Button.button>
              </div>
              <p id="people-code-timer" data-countdown phx-update="ignore" class="zaq-text-body-sm">
                The code has a limited validity period.
              </p>
              <Button.button type="submit">Sign in</Button.button>
            </.form>
            <.form for={@resend_form} id="people-resend-form" action="/people/challenge"></.form>
          </div>
        <% else %>
          <p class="zaq-text-body">Use your company email to request a one-time sign-in code.</p>
          <.form
            for={@email_form}
            id="people-email-form"
            action="/people/challenge"
            phx-hook="PeopleAuthForm"
            class="zaq-layout-stack"
          >
            <Input.input
              field={@email_form[:email]}
              id="people-email"
              type="email"
              label="Email address"
              autocomplete="email"
              required
            />
            <Button.button type="submit">Send sign-in code</Button.button>
          </.form>
        <% end %>
      </section>
    </PersonLayout.person_layout>
    """
  end
end
