defmodule ZaqWeb.PageHTML do
  @moduledoc """
  HTML templates rendered by `PageController`.

  See the `page_html` directory for all available templates.
  """
  use ZaqWeb, :html

  embed_templates "page_html/*"
end
