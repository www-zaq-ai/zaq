defmodule Zaq.TestSupport.OpenAIStubRetryTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Step.Retry
  alias Zaq.TestSupport.OpenAIStub

  test "started fixtures own distinct bound ports until supervised shutdown" do
    servers =
      for number <- 1..4 do
        {pid, endpoint} = OpenAIStub.start!(fn _conn, _body -> {200, "#{number}"} end, self())
        assert {:ok, %{status: 200, body: body}} = Req.get(endpoint)
        assert body == "#{number}"
        assert Process.alive?(pid)
        endpoint
      end

    assert length(Enum.uniq(servers)) == 4
  end

  test "immediate retries preserve all provider attempts and the final error response" do
    {child, endpoint} =
      OpenAIStub.server(fn _conn, _body -> {503, %{"error" => "unavailable"}} end, self(),
        retry_after: 0
      )

    start_supervised!(child)

    assert {:ok, response} =
             Req.new(url: endpoint)
             |> Retry.attach()
             |> Req.request()

    assert response.status == 503
    assert response.body == %{"error" => "unavailable"}
    assert Req.Response.get_header(response, "retry-after") == ["0"]

    for _attempt <- 1..4 do
      assert_receive {:openai_request, "GET", "/v1", "", ""}
    end

    refute_receive {:openai_request, _, _, _, _}, 0
  end

  test "retry timing is unchanged when a fixture does not opt in" do
    {child, endpoint} = OpenAIStub.server(fn _conn, _body -> {503, "unavailable"} end, self())
    start_supervised!(child)

    assert {:ok, response} = Req.get(endpoint, retry: false)
    assert response.status == 503
    assert response.body == "unavailable"
    assert Req.Response.get_header(response, "retry-after") == []
  end
end
