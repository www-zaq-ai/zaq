defmodule Zaq.UserPortal.ClientTest do
  use ExUnit.Case, async: true

  alias Zaq.UserPortal.Client

  @valid_metadata %{
    "status" => "ok",
    "message" => %{
      "message" => "Free credits activated — your ZAQ portal account is ready.",
      "offer_slug" => "free",
      "metadata" => %{
        "title" => "Activate your free credits",
        "body" => "To create your ZAQ account...",
        "accept_label" => "Accept & activate free credits",
        "decline_label" => "Decline — continue without free credits",
        "subtitle" => "Optional · You can skip this",
        "footnote" => "Free credits can be claimed later from the dashboard.",
        "banner_text" => "Claim your $2 in free AI credits — activate your ZAQ portal account."
      }
    }
  }

  setup do
    # This test exercises the real HTTP client, so it configures Req.Test plumbing
    # itself (the global test config mocks the client via Mox instead).
    Application.put_env(:zaq, Zaq.UserPortal.Client,
      req_options: [plug: {Req.Test, Zaq.UserPortal.Client}]
    )

    Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
      case conn.request_path do
        "/health/liveliness" ->
          Req.Test.json(conn, "I'm alive!")

        "/onboarding/free" ->
          Req.Test.json(conn, @valid_metadata)

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

  # -- fetch_onboarding/1 --

  describe "fetch_onboarding/1" do
    test "returns {:ok, metadata} when portal is reachable and metadata is valid" do
      assert {:ok, body} = Client.fetch_onboarding("free")
      assert body["message"] == "Free credits activated — your ZAQ portal account is ready."
      assert body["metadata"]["title"] == "Activate your free credits"
      assert body["offer_slug"] == "free"
    end

    test "returns :unavailable when metadata endpoint returns 503" do
      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"error" => "service_unavailable"})
      end)

      assert Client.fetch_onboarding("free") == :unavailable
    end

    test "returns :unavailable when metadata endpoint has a transport error" do
      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert Client.fetch_onboarding("free") == :unavailable
    end

    test "makes exactly one request when the portal is unreachable (no retries)" do
      test_pid = self()

      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        send(test_pid, {:portal_request, conn.request_path})
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert Client.fetch_onboarding("free") == :unavailable

      # Req's default `:safe_transient` retry would fire this 4 times for a GET;
      # `retry: false` guarantees a single attempt.
      assert_received {:portal_request, "/onboarding/free"}
      refute_received {:portal_request, _}
    end

    test "returns :unavailable when metadata endpoint returns 404" do
      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        case conn.request_path do
          "/health/liveliness" ->
            Req.Test.json(conn, "I'm alive!")

          "/onboarding/free" ->
            conn
            |> Plug.Conn.put_status(404)
            |> Req.Test.json("Not Found")
        end
      end)

      assert Client.fetch_onboarding("free") == :unavailable
    end

    test "returns :unavailable when metadata body shape is unexpected" do
      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        case conn.request_path do
          "/health/liveliness" -> Req.Test.json(conn, "I'm alive!")
          "/onboarding/free" -> Req.Test.json(conn, %{"unexpected" => "shape"})
        end
      end)

      assert Client.fetch_onboarding("free") == :unavailable
    end

    test "returns :unavailable when metadata has a transport error" do
      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        case conn.request_path do
          "/health/liveliness" -> Req.Test.json(conn, "I'm alive!")
          "/onboarding/free" -> Req.Test.transport_error(conn, :econnrefused)
        end
      end)

      assert Client.fetch_onboarding("free") == :unavailable
    end
  end

  # -- onboard_user/1 --

  describe "onboard_user/1" do
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
end
