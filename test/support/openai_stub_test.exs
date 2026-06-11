defmodule Zaq.TestSupport.OpenAIStubTest do
  use ExUnit.Case, async: true

  alias Zaq.TestSupport.OpenAIStub

  test "llm_config/2 merges overrides" do
    cfg = OpenAIStub.llm_config("http://example.test/v1", model: "override-model")
    assert cfg[:endpoint] == "http://example.test/v1"
    assert cfg[:model] == "override-model"
  end

  test "chat_completion/2 includes optional logprobs" do
    logprobs = %{"content" => [%{"token" => "ok", "logprob" => -0.1}]}
    completion = OpenAIStub.chat_completion("hello", logprobs: logprobs)

    assert completion["choices"] |> hd() |> Map.get("logprobs") == logprobs
  end

  test "server/2 builds a Bandit child spec and v1 endpoint" do
    {child_spec, endpoint} = OpenAIStub.server(fn _conn, _body -> {200, "ok"} end, self())

    assert is_tuple(child_spec)
    assert String.ends_with?(endpoint, "/v1")
  end

  test "stub call supports list and binary responses" do
    {child_spec, endpoint} =
      OpenAIStub.server(fn _conn, _body -> {200, [%{"ok" => true}]} end, self())

    start_supervised!(child_spec)

    assert {:ok, %Req.Response{status: 200, body: [%{"ok" => true}]}} =
             Req.get(endpoint <> "/list")

    {child_spec2, endpoint2} = OpenAIStub.server(fn _conn, _body -> {202, "accepted"} end, self())
    start_supervised!(child_spec2)

    assert {:ok, %Req.Response{status: 202, body: "accepted"}} = Req.get(endpoint2 <> "/text")
  end
end
