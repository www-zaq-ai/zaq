defmodule ZaqWeb.ProductionSSLConfigTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  setup do
    endpoint =
      "../../config/prod.exs"
      |> Path.expand(__DIR__)
      |> Config.Reader.read!()
      |> Keyword.fetch!(:zaq)
      |> Keyword.fetch!(ZaqWeb.Endpoint)

    ssl = Keyword.fetch!(endpoint, :force_ssl)

    # Phoenix supplies the endpoint URL host when initializing Plug.SSL.
    opts = ssl |> Keyword.put(:host, "zaq.company.com") |> Plug.SSL.init()

    %{ssl: ssl, opts: opts}
  end

  test "local HTTP exceptions are passed to Plug.SSL", %{ssl: ssl, opts: opts} do
    assert Keyword.fetch!(ssl, :exclude) == [hosts: ["localhost", "127.0.0.1"]]

    for host <- ["localhost", "127.0.0.1"] do
      conn = :get |> conn("http://#{host}:4000/bo/login") |> Plug.SSL.call(opts)

      refute conn.halted
      assert conn.scheme == :http
      assert get_resp_header(conn, "location") == []
    end
  end

  test "nonlocal HTTP redirects to the configured public HTTPS host", %{opts: opts} do
    for host <- ["zaq.company.com", "192.0.2.10"] do
      conn = :get |> conn("http://#{host}:4000/bo/login?next=home") |> Plug.SSL.call(opts)

      assert conn.halted
      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["https://zaq.company.com/bo/login?next=home"]
    end
  end

  test "proxy-forwarded HTTPS is accepted and receives HSTS", %{opts: opts} do
    conn =
      :get
      |> conn("http://zaq.company.com/bo/login")
      |> put_req_header("x-forwarded-proto", "https")
      |> Plug.SSL.call(opts)

    refute conn.halted
    assert conn.scheme == :https
    assert get_resp_header(conn, "location") == []
    assert get_resp_header(conn, "strict-transport-security") == ["max-age=31536000"]
  end

  test "proxy-forwarded HTTP still requires HTTPS", %{opts: opts} do
    conn =
      :get
      |> conn("http://zaq.company.com/bo/login")
      |> put_req_header("x-forwarded-proto", "http")
      |> Plug.SSL.call(opts)

    assert conn.halted
    assert conn.status == 301
    assert get_resp_header(conn, "location") == ["https://zaq.company.com/bo/login"]
  end
end
