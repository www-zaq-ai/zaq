defmodule Zaq.Embedding.ClientTest do
  use Zaq.DataCase, async: false

  alias Zaq.Embedding.Client
  alias Zaq.System
  alias Zaq.System.EmbeddingConfig

  setup do
    changeset =
      EmbeddingConfig.changeset(%EmbeddingConfig{}, %{
        endpoint: "http://localhost",
        api_key: "",
        model: "test-model",
        dimension: 1536
      })

    {:ok, _} = System.save_embedding_config(changeset)
    :ok
  end

  describe "config readers" do
    test "reads endpoint from config" do
      assert Client.endpoint() == "http://localhost"
    end

    test "reads model from config" do
      assert Client.model() == "test-model"
    end

    test "reads dimension from config" do
      assert Client.dimension() == 1536
    end
  end

  describe "embed/2" do
    test "returns embedding on successful response" do
      embedding = List.duplicate(0.1, 10)

      Req.Test.stub(Client, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["model"] == "test-model"
        assert decoded["input"] == "Hello world"

        Req.Test.json(conn, %{
          "data" => [%{"embedding" => embedding}]
        })
      end)

      assert {:ok, ^embedding} = Client.embed("Hello world")
    end

    test "allows model override via opts" do
      Req.Test.stub(Client, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["model"] == "custom-model"

        Req.Test.json(conn, %{
          "data" => [%{"embedding" => [0.1, 0.2]}]
        })
      end)

      assert {:ok, [0.1, 0.2]} = Client.embed("test", model: "custom-model")
    end

    test "returns error on unexpected response format" do
      Req.Test.stub(Client, fn conn ->
        Req.Test.json(conn, %{"unexpected" => "format"})
      end)

      assert {:error, "Unexpected response format:" <> _} = Client.embed("test")
    end

    test "returns error on non-200 status" do
      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "unauthorized"})
      end)

      assert {:error, "API error (401):" <> _} = Client.embed("test")
    end

    test "returns rate_limited error with retry-after delay" do
      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "120")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => "rate limited"})
      end)

      assert {:error, {:rate_limited, 120, %{status: 429}}} = Client.embed("test")
    end

    test "returns rate_limited error with retry-after HTTP-date delay" do
      retry_after =
        DateTime.utc_now()
        |> DateTime.add(75, :second)
        |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", retry_after)
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => "rate limited"})
      end)

      assert {:error, {:rate_limited, delay_seconds, %{status: 429}}} = Client.embed("test")
      assert delay_seconds >= 60
      assert delay_seconds <= 75
    end

    test "falls back to rate limit reset header when retry-after is missing" do
      reset_at = DateTime.utc_now() |> DateTime.to_unix() |> Kernel.+(90)

      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-reset", Integer.to_string(reset_at))
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => "rate limited"})
      end)

      assert {:error, {:rate_limited, delay_seconds, %{status: 429}}} = Client.embed("test")
      assert delay_seconds >= 75
      assert delay_seconds <= 90
    end

    test "defaults to 60 seconds when no rate limit headers are present" do
      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => "rate limited"})
      end)

      assert {:error, {:rate_limited, 60, %{status: 429}}} = Client.embed("test")
    end

    test "skips authorization header when api_key is empty" do
      Req.Test.stub(Client, fn conn ->
        auth_header = Plug.Conn.get_req_header(conn, "authorization")
        assert auth_header == []

        Req.Test.json(conn, %{
          "data" => [%{"embedding" => [0.1]}]
        })
      end)

      assert {:ok, [0.1]} = Client.embed("test")
    end

    test "includes authorization header when api_key is set" do
      changeset =
        EmbeddingConfig.changeset(%EmbeddingConfig{}, %{
          endpoint: "http://localhost",
          api_key: "sk-test-key",
          model: "test-model",
          dimension: 1536
        })

      {:ok, _} = System.save_embedding_config(changeset)

      Req.Test.stub(Client, fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == "Bearer sk-test-key"

        Req.Test.json(conn, %{
          "data" => [%{"embedding" => [0.1]}]
        })
      end)

      assert {:ok, [0.1]} = Client.embed("test")
    end
  end
end
