defmodule ZaqWeb.PortalConnectHTML do
  use ZaqWeb, :html

  alias ZaqWeb.Components.DesignSystem.AuthLayout
  alias ZaqWeb.Live.BO.System.PortalConnectPasswordLive

  embed_templates "portal_connect_html/*"
end
