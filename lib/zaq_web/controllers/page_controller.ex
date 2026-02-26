defmodule ZaqWeb.PageController do
  use ZaqWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
