defmodule Zaq.UserPortal.ClientTest do
  use ExUnit.Case, async: true

  alias Zaq.UserPortal.Client

  setup do
    Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
      case conn.request_path do
        "/onboarding" ->
          Req.Test.json(conn, %{
            "status" => "ok",
            "user" => %{
              "id" => 1,
              "email" => "admin@example.com",
              "plan" => "free",
              "litellm_user_id" => "llm-user-test",
              "litellm_api_key" => "sk-test-key"
            }
          })
      end
    end)

    :ok
  end

  test "returns litellm_api_key on success" do
    assert {:ok, %{litellm_api_key: "sk-test-key"}} = Client.onboard_user("admin@example.com")
  end

  test "returns error on 400 response" do
    Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => "invalid_payload"})
    end)

    assert {:error, {400, %{"error" => "invalid_payload"}}} =
             Client.onboard_user("bad@example.com")
  end

  test "returns error on 500 response" do
    Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(500)
      |> Req.Test.json(%{"error" => "delivery_failed"})
    end)

    assert {:error, {500, _}} = Client.onboard_user("admin@example.com")
  end
end
