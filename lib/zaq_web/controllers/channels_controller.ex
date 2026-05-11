defmodule ZaqWeb.ChannelsController do
  use ZaqWeb, :controller

  def health(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
