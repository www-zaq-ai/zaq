defmodule ZaqWeb.PageController do
  use ZaqWeb, :controller

  def home(conn, _params) do
    case get_session(conn, :user_id) do
      nil -> redirect(conn, to: ~p"/bo/login")
      _user_id -> redirect(conn, to: ~p"/bo/dashboard")
    end
  end
end
