defmodule ZaqWeb.PeopleProfileRoutingTest do
  use ExUnit.Case, async: true

  test "the retired profile preview is not routable" do
    assert Phoenix.Router.route_info(ZaqWeb.Router, "GET", "/people/profile/preview", "localhost") ==
             :error
  end
end
