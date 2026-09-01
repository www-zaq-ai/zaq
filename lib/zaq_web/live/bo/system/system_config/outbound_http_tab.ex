defmodule ZaqWeb.Live.BO.System.SystemConfig.OutboundHttpTab do
  @moduledoc """
  Outbound HTTP policy and credential provider management for system config.
  """
  use ZaqWeb, :html

  alias Zaq.System.OutboundHttpPolicy
  alias ZaqWeb.Components.BOModal
  alias ZaqWeb.Components.DesignSystem.Button
  alias ZaqWeb.Components.DesignSystem.Input
  alias ZaqWeb.Components.DesignSystem.Switch
  alias ZaqWeb.Components.DesignSystem.Table

  attr :policy_form, :any, required: true
  attr :providers, :list, required: true
  attr :provider_modal, :boolean, required: true
  attr :provider_form, :any, required: true
  attr :provider_action, :atom, required: true

  def panel(assigns) do
    ~H"""
    <div class="zaq-layout-stack zaq-layout-stack--lg">
      <section class="zaq-card-default overflow-hidden">
        <div class="zaq-layout-inline zaq-layout-inline--between zaq-border-bottom px-8 py-5">
          <div class="zaq-layout-stack zaq-layout-stack--xs">
            <p class="zaq-text-eyebrow">Security boundary</p>
            <h2 class="zaq-text-heading-sm">Outbound HTTP</h2>
            <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
              Global policy for agent and workflow HTTP requests. The default posture is fail-closed.
            </p>
          </div>
          <span class={policy_badge_class(@policy_form[:enabled].value)}>
            {if truthy?(@policy_form[:enabled].value), do: "enabled", else: "disabled"}
          </span>
        </div>

        <.form
          for={@policy_form}
          phx-submit="save_outbound_http_policy"
          class="p-8 zaq-layout-stack zaq-layout-stack--lg"
        >
          <.warning_panel :if={weakened_policy?(@policy_form)} form={@policy_form} />

          <div class="zaq-card-subtle p-5">
            <Switch.switch
              field={@policy_form[:enabled]}
              layout={:setting_row}
              label="Enable outbound HTTP requests"
              description="When off, agent and workflow HTTP requests fail before transport."
            />
          </div>

          <div class="grid gap-5 lg:grid-cols-2">
            <div class="zaq-card-subtle p-5 zaq-layout-stack">
              <div>
                <h3 class="zaq-text-heading-xs">Allowed Transport</h3>
                <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
                  Keep methods and ports narrow. Blank ports means standard URL ports are allowed.
                </p>
              </div>
              <Input.input
                id="outbound_http_policy_allowed_methods_text"
                name="outbound_http_policy[allowed_methods_text]"
                label="Allowed methods"
                value={join_list(@policy_form[:allowed_methods].value)}
                placeholder="GET, HEAD, OPTIONS"
              />
              <Input.input
                id="outbound_http_policy_allowed_ports_text"
                name="outbound_http_policy[allowed_ports_text]"
                label="Allowed ports"
                value={join_list(@policy_form[:allowed_ports].value)}
                placeholder="443, 8443"
              />
              <Input.input
                field={@policy_form[:max_timeout_ms]}
                type="number"
                label="Maximum timeout (ms)"
                min="1"
                max="120000"
              />
              <Input.input
                field={@policy_form[:max_response_bytes]}
                type="number"
                label="Maximum response bytes"
                min="1"
                max="10000000"
              />
              <Switch.switch
                field={@policy_form[:follow_redirects]}
                layout={:setting_row}
                label="Follow redirects"
                description="Disabled for now. Redirect handling will be available in a future update once each hop can be revalidated safely."
                disabled
              />
            </div>

            <div class="zaq-card-subtle p-5 zaq-layout-stack">
              <div>
                <h3 class="zaq-text-heading-xs">Network Protections</h3>
                <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
                  These SSRF controls block private and special-use destinations after DNS resolution.
                </p>
              </div>
              <.protection_switch
                field={@policy_form[:block_loopback]}
                label="Block loopback"
                description="Blocks 127.0.0.0/8 and ::1."
              />
              <.protection_switch
                field={@policy_form[:block_private_networks]}
                label="Block private networks"
                description="Blocks RFC1918 address ranges."
              />
              <.protection_switch
                field={@policy_form[:block_link_local]}
                label="Block link-local"
                description="Blocks 169.254.0.0/16 and fe80::/10."
              />
              <.protection_switch
                field={@policy_form[:block_cloud_metadata]}
                label="Block cloud metadata"
                description="Blocks 169.254.169.254."
              />
              <.protection_switch
                field={@policy_form[:block_carrier_grade_nat]}
                label="Block carrier-grade NAT"
                description="Blocks 100.64.0.0/10."
              />
              <.protection_switch
                field={@policy_form[:block_multicast]}
                label="Block multicast"
                description="Blocks multicast destinations."
              />
              <.protection_switch
                field={@policy_form[:block_unspecified]}
                label="Block unspecified"
                description="Blocks 0.0.0.0 and ::."
              />
              <.protection_switch
                field={@policy_form[:block_reserved]}
                label="Block reserved ranges"
                description="Blocks documentation, future-use, and reserved ranges."
              />
              <.protection_switch
                field={@policy_form[:block_ipv6_unique_local]}
                label="Block IPv6 unique-local"
                description="Blocks fc00::/7."
              />
            </div>
          </div>

          <div class="zaq-card-subtle p-5 zaq-layout-stack">
            <div>
              <h3 class="zaq-text-heading-xs">Destination Blacklists</h3>
              <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
                Add one value per line or comma-separated. Blacklists always override provider host patterns.
              </p>
            </div>
            <div class="grid gap-5 lg:grid-cols-3">
              <Input.input
                type="textarea"
                id="outbound_http_policy_blacklisted_hosts_text"
                name="outbound_http_policy[blacklisted_hosts_text]"
                label="Blacklisted hosts"
                value={join_lines(@policy_form[:blacklisted_hosts].value)}
                rows="4"
                placeholder="metadata.google.internal"
              />
              <Input.input
                type="textarea"
                id="outbound_http_policy_blacklisted_ips_text"
                name="outbound_http_policy[blacklisted_ips_text]"
                label="Blacklisted IPs"
                value={join_lines(@policy_form[:blacklisted_ips].value)}
                rows="4"
                placeholder="169.254.169.254"
              />
              <Input.input
                type="textarea"
                id="outbound_http_policy_blacklisted_cidrs_text"
                name="outbound_http_policy[blacklisted_cidrs_text]"
                label="Blacklisted CIDRs"
                value={join_lines(@policy_form[:blacklisted_cidrs].value)}
                rows="4"
                placeholder="10.0.0.0/8"
              />
            </div>
          </div>

          <div class="zaq-layout-inline zaq-layout-inline--end">
            <Button.button type="submit" icon="hero-shield-check">Save policy</Button.button>
          </div>
        </.form>
      </section>

      <section class="zaq-card-default overflow-hidden">
        <div class="zaq-layout-inline zaq-layout-inline--between zaq-border-bottom px-8 py-5">
          <div class="zaq-layout-stack zaq-layout-stack--xs">
            <p class="zaq-text-eyebrow">Credential rendering</p>
            <h2 class="zaq-text-heading-sm">HTTP Credential Providers</h2>
            <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
              Providers define non-secret rendering rules. Auth Credentials hold encrypted secret material.
            </p>
          </div>
          <Button.button phx-click="new_http_credential_provider" icon="hero-plus">New provider</Button.button>
        </div>

        <div class="p-8">
          <Table.table id="http-credential-providers" min_width="720px">
            <:head>
              <Table.table_head_row>
                <Table.table_cell element={:th}>Provider</Table.table_cell>
                <Table.table_cell element={:th}>Rendering</Table.table_cell>
                <Table.table_cell element={:th}>Hosts</Table.table_cell>
                <Table.table_cell element={:th} align={:right}>Actions</Table.table_cell>
              </Table.table_head_row>
            </:head>
            <:body>
              <Table.table_empty :if={@providers == []} colspan={4}>
                No HTTP credential providers configured.
              </Table.table_empty>
              <Table.table_row :for={provider <- @providers} id={"http-provider-#{provider.id}"}>
                <Table.table_cell>
                  <div class="zaq-layout-stack zaq-layout-stack--xs">
                    <Table.table_text label={provider.name} />
                    <span class={provider_badge_class(provider.enabled)}>{if provider.enabled,
                      do: "enabled",
                      else: "disabled"}</span>
                  </div>
                </Table.table_cell>
                <Table.table_cell>
                  <Table.table_text label={rendering_summary(provider)} tone={:secondary} />
                </Table.table_cell>
                <Table.table_cell>
                  <Table.table_text
                    label={Enum.join(provider.host_patterns, ", ")}
                    tone={:secondary}
                    truncate
                  />
                </Table.table_cell>
                <Table.table_cell align={:right}>
                  <div class="zaq-layout-inline zaq-layout-inline--end">
                    <Button.button
                      variant={:tertiary}
                      phx-click="edit_http_credential_provider"
                      phx-value-id={provider.id}
                    >Edit</Button.button>
                    <Button.button
                      variant={:tertiary}
                      danger
                      phx-click="delete_http_credential_provider"
                      phx-value-id={provider.id}
                    >Delete</Button.button>
                  </div>
                </Table.table_cell>
              </Table.table_row>
            </:body>
          </Table.table>
        </div>
      </section>
    </div>

    <BOModal.form_dialog
      :if={@provider_modal}
      id="http-credential-provider-modal"
      cancel_event="close_http_credential_provider_modal"
      title={if @provider_action == :new, do: "New HTTP Provider", else: "Edit HTTP Provider"}
      max_width_class="zaq-modal--width-lg"
    >
      <.form for={@provider_form} phx-submit="save_http_credential_provider" class="zaq-layout-stack">
        <Input.input field={@provider_form[:name]} label="Name" />
        <div class="grid gap-5 md:grid-cols-2">
          <div class="zaq-field-row-block">
            <label class="zaq-field-label-uppercase zaq-text-caption">Auth kind</label>
            <select name="http_credential_provider[auth_kind]" class="w-full zaq-control-text">
              <option value="bearer" selected={@provider_form[:auth_kind].value == "bearer"}>
                Bearer
              </option>
              <option value="api_key" selected={@provider_form[:auth_kind].value == "api_key"}>
                API key
              </option>
              <option value="basic" selected={@provider_form[:auth_kind].value == "basic"}>
                Basic
              </option>
              <option value="custom" selected={@provider_form[:auth_kind].value == "custom"}>
                Custom
              </option>
            </select>
          </div>
          <div class="zaq-field-row-block">
            <label class="zaq-field-label-uppercase zaq-text-caption">Placement</label>
            <select name="http_credential_provider[placement]" class="w-full zaq-control-text">
              <option
                value="authorization"
                selected={@provider_form[:placement].value == "authorization"}
              >
                Authorization
              </option>
              <option value="header" selected={@provider_form[:placement].value == "header"}>
                Header
              </option>
              <option value="query" selected={@provider_form[:placement].value == "query"}>
                Query
              </option>
            </select>
          </div>
        </div>
        <Input.input
          field={@provider_form[:parameter_name]}
          label="Parameter name"
          placeholder="x-api-key"
        />
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
          Required for header/query placement and blank for authorization placement. Provider host patterns only narrow global policy.
        </p>
        <Input.input
          type="textarea"
          id="http_credential_provider_host_patterns_text"
          name="http_credential_provider[host_patterns_text]"
          label="Host patterns"
          value={join_lines(@provider_form[:host_patterns].value)}
          rows="4"
          placeholder="api.example.com&#10;.uploads.example.com"
        />
        <Input.input
          type="textarea"
          id="http_credential_provider_metadata_text"
          name="http_credential_provider[metadata_text]"
          label="Non-secret metadata JSON"
          value={metadata_text(@provider_form[:metadata].value)}
          rows="4"
          placeholder={~s({"owner":"integrations"})}
        />
        <Switch.switch
          field={@provider_form[:enabled]}
          layout={:setting_row}
          label="Provider enabled"
          description="Disabled providers cannot render credentials into requests."
        />
        <div class="zaq-layout-inline zaq-layout-inline--end">
          <Button.button variant={:secondary} phx-click="close_http_credential_provider_modal">Cancel</Button.button>
          <Button.button type="submit">Save provider</Button.button>
        </div>
      </.form>
    </BOModal.form_dialog>
    """
  end

  attr :field, :any, required: true
  attr :label, :string, required: true
  attr :description, :string, required: true

  defp protection_switch(assigns) do
    ~H"""
    <Switch.switch field={@field} layout={:setting_row} label={@label} description={@description} />
    """
  end

  attr :form, :any, required: true

  defp warning_panel(assigns) do
    ~H"""
    <div
      class="zaq-card-subtle p-5 zaq-layout-stack zaq-layout-stack--sm"
      style="border-color: var(--zaq-border-color-warning)"
    >
      <h3 class="zaq-text-heading-xs">Weakened protections</h3>
      <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
        One or more secure defaults have been relaxed. Review whether this is necessary before saving.
      </p>
    </div>
    """
  end

  defp weakened_policy?(form) do
    unsafe_methods? =
      form[:allowed_methods].value
      |> List.wrap()
      |> Enum.any?(&(&1 not in OutboundHttpPolicy.safe_methods()))

    protections_relaxed? =
      ~w(block_loopback block_private_networks block_link_local block_cloud_metadata block_carrier_grade_nat block_multicast block_unspecified block_reserved block_ipv6_unique_local)a
      |> Enum.any?(&(not truthy?(form[&1].value)))

    truthy?(form[:follow_redirects].value) or unsafe_methods? or protections_relaxed?
  end

  defp policy_badge_class(value) do
    if truthy?(value),
      do: "zaq-pill zaq-text-caption zaq-pill--success",
      else: "zaq-pill zaq-text-caption zaq-pill--elevated"
  end

  defp provider_badge_class(true), do: "zaq-pill zaq-text-caption zaq-pill--success"
  defp provider_badge_class(_), do: "zaq-pill zaq-text-caption zaq-pill--elevated"

  defp rendering_summary(provider) do
    [provider.auth_kind, provider.placement, provider.parameter_name]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp metadata_text(value) when value in [nil, %{}], do: ""
  defp metadata_text(value) when is_map(value), do: Jason.encode!(value)
  defp metadata_text(_), do: ""

  defp truthy?(value), do: value in [true, "true", "on", "1", 1]

  defp join_lines(values) when is_list(values), do: Enum.join(values, "\n")
  defp join_lines(_), do: ""
  defp join_list(values) when is_list(values), do: Enum.join(values, ", ")
  defp join_list(_), do: ""
end
