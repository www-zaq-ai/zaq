defmodule Zaq.Embedding.ClientTest do
  use ExUnit.Case, async: true

  alias Zaq.Embedding.Client

  # Config is set in config/test.exs:
  #
  #   config :zaq, Zaq.Embedding.Client,
  #     endpoint: "http://localhost",
  #     api_key: "",
  #     model: "test-model",
  #     dimension: 1536,
  #     req_options: [plug: {Req.Test, Zaq.Embedding.Client}]

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
      original = Application.get_env(:zaq, Client)

      Application.put_env(:zaq, Client, Keyword.merge(original, api_key: "sk-test-key"))

      Req.Test.stub(Client, fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == "Bearer sk-test-key"

        Req.Test.json(conn, %{
          "data" => [%{"embedding" => [0.1]}]
        })
      end)

      assert {:ok, [0.1]} = Client.embed("test")

      # Restore
      Application.put_env(:zaq, Client, original)
    end
  end
end
