defmodule Zaq.TestSupport.HTTPFixtureOptionsTest do
  use ExUnit.Case, async: false

  alias Zaq.TestSupport.{HTTPFixtureOptions, OpenAIStub}

  defmodule TimeoutProbe do
    def run(request) do
      {request, Req.Response.new(status: 200, body: request.options.receive_timeout)}
    end
  end

  test "an HTTP 500 still makes all four attempts with immediate fixture retries" do
    {child, endpoint} = OpenAIStub.server(fn _conn, _body -> {500, "failed"} end, self())
    start_supervised!(child)
    HTTPFixtureOptions.configure(endpoint, retry_delay: fn _attempt -> 0 end)

    assert {:ok, %{status: 500, body: "failed"}} = Req.get(endpoint)

    for _attempt <- 1..4 do
      assert_receive {:openai_request, "GET", "/v1", "", ""}
    end

    refute_receive {:openai_request, _, _, _, _}, 0
  end

  test "only requests matching the fixture origin and path receive its options" do
    HTTPFixtureOptions.configure("http://127.0.0.1:1234/api/", receive_timeout: 123)

    for {url, expected} <- [
          {"http://127.0.0.1:1234/api/posts", 123},
          {"http://127.0.0.1:1234/v1/responses", 999},
          {"http://127.0.0.1:4321/api/posts", 999},
          {"https://127.0.0.1:1234/api/posts", 999}
        ] do
      assert {:ok, %{status: 200, body: ^expected}} =
               Req.get(url, receive_timeout: 999, adapter: TimeoutProbe)
    end
  end

  test "a request predicate leaves other messages on the same endpoint unchanged" do
    url = "http://127.0.0.1:1234/api/posts"

    HTTPFixtureOptions.configure(url, [receive_timeout: 123], fn request ->
      get_in(request.options, [:json, "message"]) == "terminal"
    end)

    for {message, expected} <- [{"progress", 999}, {"terminal", 123}] do
      assert {:ok, %{status: 200, body: ^expected}} =
               Req.post(url,
                 json: %{"message" => message},
                 receive_timeout: 999,
                 adapter: TimeoutProbe
               )
    end
  end
end
