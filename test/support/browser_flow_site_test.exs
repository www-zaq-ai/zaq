defmodule Zaq.TestSupport.BrowserFlowSiteTest do
  use ExUnit.Case, async: true

  alias Zaq.TestSupport.BrowserFlowSite

  test "serves two HTML pages and records decoded form submission" do
    opts = BrowserFlowSite.init(test_pid: self(), nonce: "test-nonce")

    for path <- ["/", "/form"] do
      conn = BrowserFlowSite.call(Plug.Test.conn(:get, path), opts)
      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
      assert_received {:browser_page, ^path}
    end

    body = URI.encode_query(%{"message" => "Ada & QA", "nonce" => "test-nonce"})

    conn =
      Plug.Test.conn(:post, "/submit", body)
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> BrowserFlowSite.call(opts)

    assert conn.status == 200
    assert conn.resp_body =~ "Submission received."
    assert_received {:browser_submission, %{"message" => "Ada & QA", "nonce" => "test-nonce"}}
  end

  test "rejects invalid submissions and unknown routes without recording actions" do
    opts = BrowserFlowSite.init(test_pid: self(), nonce: "expected")

    for body <- ["nonce=wrong&message=hello", "nonce=expected"] do
      conn =
        Plug.Test.conn(:post, "/submit", body)
        |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
        |> BrowserFlowSite.call(opts)

      assert conn.status == 422
      refute_received {:browser_submission, _}
    end

    assert BrowserFlowSite.call(Plug.Test.conn(:get, "/missing"), opts).status == 404
    assert BrowserFlowSite.call(Plug.Test.conn(:get, "/favicon.ico"), opts).status == 204
  end
end
