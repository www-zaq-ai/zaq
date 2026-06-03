defmodule ZaqWeb.Components.PortalConsentModal do
  @moduledoc """
  Dark-themed consent modal for ZAQ portal account provisioning.

  Explains what data is collected (email + machine fingerprint) and why,
  then lets the user accept or decline. Used during bootstrap onboarding
  and from the dashboard retry banner.

  ## Email capture

  When `require_email` is `true` (e.g. an older account that has no email on
  file), the modal renders an email input and disables the accept button until
  a non-blank email is provided. Track the value in the parent LiveView via the
  `on_email_change` event and feed it back through the `email` assign.

  ## Usage

      <ZaqWeb.Components.PortalConsentModal.portal_consent_modal
        show={@show_consent_modal}
        on_accept="accept_portal_consent"
        on_decline="decline_portal_consent"
        decline_label="Decline — continue without free credits"
        subtitle="Optional · You can skip this"
        footnote="Free credits can be claimed later from the dashboard."
        require_email={@require_portal_email}
        email={@portal_consent_email}
        on_email_change="portal_consent_email_change"
        error={nil}
      />
  """

  use ZaqWeb, :html

  attr :show, :boolean, required: true
  attr :on_accept, :string, default: "accept_portal_consent"
  attr :on_decline, :string, required: true
  attr :decline_label, :string, default: "Decline — continue without free credits"
  attr :subtitle, :string, default: "Optional · You can skip this"
  attr :footnote, :string, default: nil
  attr :error, :string, default: nil
  attr :require_email, :boolean, default: false
  attr :email, :string, default: nil
  attr :on_email_change, :string, default: "portal_consent_email_change"

  def portal_consent_modal(assigns) do
    assigns =
      assign(
        assigns,
        :accept_disabled,
        assigns.require_email and not email_present?(assigns.email)
      )

    ~H"""
    <div
      :if={@show}
      class="fixed inset-0 z-50 flex items-center justify-center px-4"
      style="background: rgba(6,10,18,0.85); backdrop-filter: blur(4px);"
    >
      <div
        class="relative w-full max-w-[460px] rounded-2xl border border-[#1b2538] p-8 shadow-2xl shadow-black/60 overflow-hidden"
        style="background: #0d1320;"
      >
        <div
          class="absolute top-0 left-0 right-0 h-[2px] rounded-t-2xl"
          style="background: linear-gradient(90deg, transparent, #22d3ee, #34d399, transparent); opacity: 0.7;"
        >
        </div>

        <div class="flex items-start gap-4 mb-6">
          <div
            class="shrink-0 w-11 h-11 rounded-xl border border-cyan-500/20 grid place-items-center mt-0.5"
            style="background: linear-gradient(135deg, rgba(34,211,238,0.12), rgba(52,211,153,0.08));"
          >
            <svg
              class="w-5 h-5 text-cyan-400"
              fill="none"
              stroke="currentColor"
              stroke-width="1.8"
              viewBox="0 0 24 24"
            >
              <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" />
            </svg>
          </div>
          <div>
            <h2 class="font-mono text-base font-bold text-white tracking-tight">
              Activate your free credits
            </h2>
            <p class="font-mono text-[0.72rem] text-[#4a5a7a] tracking-wide mt-1">
              {@subtitle}
            </p>
          </div>
        </div>

        <p class="font-mono text-[0.8rem] text-[#8b9cc0] leading-relaxed mb-4">
          To create your ZAQ account and unlock <span class="text-cyan-300 font-semibold">$2 in free AI credits</span>, we need to send the following to the ZAQ user portal:
        </p>
        <ul class="space-y-2 mb-5">
          <li class="flex items-center gap-2 font-mono text-[0.78rem] text-[#8b9cc0]">
            <svg
              class="w-4 h-4 text-cyan-500 shrink-0"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              viewBox="0 0 24 24"
            >
              <path d="M4 6h16v12H4z" /><path d="m4 7 8 6 8-6" />
            </svg>
            Your email address
          </li>
          <li class="flex items-center gap-2 font-mono text-[0.78rem] text-[#8b9cc0]">
            <svg
              class="w-4 h-4 text-cyan-500 shrink-0"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              viewBox="0 0 24 24"
            >
              <rect x="2" y="3" width="20" height="14" rx="2" /><path d="M8 21h8M12 17v4" />
            </svg>
            A machine fingerprint (anonymous hardware identifier)
          </li>
        </ul>

        <form :if={@require_email} phx-change={@on_email_change} class="mb-5">
          <label
            for="portal-consent-email"
            class="block font-mono text-[0.72rem] text-[#4a5a7a] tracking-wide mb-2"
          >
            We don't have your email on file — enter it to continue
          </label>
          <input
            id="portal-consent-email"
            type="email"
            name="email"
            value={@email}
            required
            autocomplete="email"
            placeholder="you@company.com"
            class="w-full rounded-xl border border-[#1b2538] bg-[#0a0f1a] px-4 py-2.5 font-mono text-[0.8rem] text-white placeholder:text-[#3a4a6a] focus:border-cyan-500/50 focus:outline-none"
          />
        </form>

        <p :if={@footnote} class="font-mono text-[0.72rem] text-[#4a5a7a] leading-relaxed mb-5">
          {@footnote}
        </p>

        <div
          :if={@error}
          class="mb-4 flex items-center gap-2 rounded-lg border border-red-500/20 bg-red-500/10 px-4 py-2.5 font-mono text-[0.75rem] text-red-400"
        >
          <svg
            class="w-4 h-4 shrink-0"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            viewBox="0 0 24 24"
          >
            <circle cx="12" cy="12" r="10" /><path d="M12 8v4m0 4h.01" />
          </svg>
          {@error}
        </div>

        <div class="flex flex-col gap-3">
          <button
            phx-click={@on_accept}
            disabled={@accept_disabled}
            class="btn btn-block rounded-xl h-11 text-[0.85rem] tracking-wide uppercase font-mono font-bold border-none transition-all duration-300 hover:shadow-[0_0_24px_-4px_rgba(34,211,238,0.35)] hover:-translate-y-[1px] active:translate-y-0 disabled:opacity-40 disabled:cursor-not-allowed disabled:shadow-none disabled:hover:translate-y-0"
            style="background: linear-gradient(135deg, #22d3ee, #34d399); color: #060a12;"
          >
            Accept &amp; activate free credits
          </button>
          <button
            phx-click={@on_decline}
            class="btn btn-block rounded-xl h-11 text-[0.85rem] tracking-wide font-mono border border-[#1b2538] text-[#6f7f9f] bg-transparent hover:border-[#2a3a55] hover:text-[#8b9cc0] transition-all"
          >
            {@decline_label}
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp email_present?(email),
    do: is_binary(email) and Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, String.trim(email))
end
