defmodule Zaq.UserPortal.ClientTest do
  use ExUnit.Case, async: false

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

        "/account/email" ->
          Req.Test.json(conn, %{"ok" => true})
      end
    end)

    previous_lang = System.get_env("LANG")
    previous_lc_all = System.get_env("LC_ALL")
    previous_lc_messages = System.get_env("LC_MESSAGES")

    on_exit(fn ->
      restore_env("LANG", previous_lang)
      restore_env("LC_ALL", previous_lc_all)
      restore_env("LC_MESSAGES", previous_lc_messages)
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

    test "sends network block and machine_signals in request body" do
      test_pid = self()

      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(body)})

        Req.Test.json(conn, %{
          "status" => "ok",
          "user" => %{"litellm_api_key" => "sk-test-key"}
        })
      end)

      assert {:ok, _} = Client.onboard_user("admin@example.com")

      assert_received {:request_body, body}
      assert %{"network" => network} = body
      assert is_binary(network["user_agent"])
      assert String.starts_with?(network["user_agent"], "ZaqApp/")
      # accept_lang and timezone_offset_minutes may be nil depending on the environment
      assert Map.has_key?(network, "accept_lang")
      assert Map.has_key?(network, "timezone_offset_minutes")
      # IP fields are not sent by the client — enriched portal-side
      refute Map.has_key?(network, "ip")
      refute Map.has_key?(network, "ip_country")
      refute Map.has_key?(network, "is_vpn")
      refute Map.has_key?(network, "is_tor")
      assert Map.has_key?(body, "machine_signals")
      assert body["machine_signals"]["version"] == 1
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

    test "returns error on transport error" do
      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Client.onboard_user("admin@example.com")
    end

    test "sends nil locale when no locale environment variable is set" do
      System.delete_env("LANG")
      System.delete_env("LC_ALL")
      System.delete_env("LC_MESSAGES")

      test_pid = self()

      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(body)})

        Req.Test.json(conn, %{
          "status" => "ok",
          "user" => %{"litellm_api_key" => "sk-test-key"}
        })
      end)

      assert {:ok, _} = Client.onboard_user("admin@example.com")
      assert_received {:request_body, %{"network" => %{"accept_lang" => nil}}}
    end
  end

  # -- update_email/2 --

  describe "update_email/2" do
    test "returns :ok on 200" do
      assert :ok = Client.update_email("new@example.com", "sk-test-key")
    end

    test "sends PATCH to /account/email with litellm_api_key as Bearer token and email body" do
      test_pid = self()

      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        send(test_pid, {:request, conn.method, conn.request_path, auth, Jason.decode!(body)})
        Req.Test.json(conn, %{"ok" => true})
      end)

      assert :ok = Client.update_email("new@example.com", "sk-my-key")

      assert_received {:request, "PATCH", "/account/email", "Bearer sk-my-key",
                       %{"email" => "new@example.com"}}
    end

    test "returns {:error, :portal_sync_failed} when api_key is nil" do
      assert {:error, :portal_sync_failed} = Client.update_email("user@example.com", nil)
    end

    test "returns {:error, :email_taken} on 409" do
      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        conn
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{"error" => "email_taken"})
      end)

      assert {:error, :email_taken} = Client.update_email("taken@example.com", "sk-test-key")
    end

    test "returns {:error, :same_email} on 422" do
      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"error" => "same_email"})
      end)

      assert {:error, :same_email} = Client.update_email("same@example.com", "sk-test-key")
    end

    test "returns {:error, :unauthorized} on 401" do
      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "unauthorized"})
      end)

      assert {:error, :unauthorized} = Client.update_email("user@example.com", "sk-test-key")
    end

    test "returns {:error, :invalid_email} on 400 invalid_email" do
      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "invalid_email"})
      end)

      assert {:error, :invalid_email} = Client.update_email("notanemail", "sk-test-key")
    end

    test "returns {:error, :invalid_payload} on other 400 responses" do
      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "invalid_payload"})
      end)

      assert {:error, :invalid_payload} = Client.update_email("bad@example.com", "sk-test-key")
    end

    test "returns {:error, :account_suspended} on 403" do
      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => "account_suspended"})
      end)

      assert {:error, :account_suspended} =
               Client.update_email("user@example.com", "sk-test-key")
    end

    test "returns status and body for unknown portal errors" do
      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        conn
        |> Plug.Conn.put_status(418)
        |> Req.Test.json(%{"error" => "teapot"})
      end)

      assert {:error, {418, %{"error" => "teapot"}}} =
               Client.update_email("user@example.com", "sk-test-key")
    end

    test "returns {:error, reason} on transport error" do
      Req.Test.stub(Zaq.UserPortal.Client, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, _} = Client.update_email("user@example.com", "sk-test-key")
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
