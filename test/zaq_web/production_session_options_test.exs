defmodule ZaqWeb.ProductionSessionOptionsTest do
  use ExUnit.Case, async: true

  test "actual endpoint session options evaluated with production config emit Secure without persistent expiry" do
    config = Config.Reader.read!("config/prod.exs", env: :prod, target: :host)
    assert config[:zaq][:secure_session_cookie] == true
    ast = "lib/zaq_web/endpoint.ex" |> File.read!() |> Code.string_to_quoted!()

    {:@, _, [{:session_options, _, [options]}]} =
      ast |> Macro.prewalker() |> Enum.find(&match?({:@, _, [{:session_options, _, [_]}]}, &1))

    options =
      Macro.prewalk(options, fn
        {{:., _, [{:__aliases__, _, [:Application]}, :compile_env]}, _, [:zaq, key, default]} ->
          Keyword.get(config[:zaq], key, default)

        node ->
          node
      end)

    {options, []} = Code.eval_quoted(options)
    conn = %{Plug.Test.conn(:get, "/") | secret_key_base: String.duplicate("p", 64)}

    conn =
      conn
      |> Plug.Session.call(Plug.Session.init(options))
      |> Plug.Conn.fetch_session()
      |> Plug.Conn.put_session(:user_id, 1)
      |> Plug.Conn.send_resp(200, "ok")

    cookie = conn.resp_cookies["_zaq_key"]
    assert cookie.secure
    assert cookie.http_only
    assert cookie.same_site == "Lax"
    refute Map.has_key?(cookie, :max_age)
  end
end
