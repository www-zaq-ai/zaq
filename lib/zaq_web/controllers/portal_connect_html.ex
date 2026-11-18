defmodule ZaqWeb.PortalConnectHTML do
  use ZaqWeb, :html

  alias ZaqWeb.Components.DesignSystem.{AuthLayout, Button, SecretInput}

  embed_templates "portal_connect_html/*"
end
