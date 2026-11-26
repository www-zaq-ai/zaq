defmodule Zaq.Agent.Tools.Ingestion.GenerateEmbeddingsTest do
  use Zaq.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn

  alias Zaq.Agent.Tools.Ingestion.{ChunkContent, GenerateEmbeddings}
  alias Zaq.Embedding.Client
  alias Zaq.Ingestion.{Document, IngestJob}
  alias Zaq.SystemConfigFixtures

  setup do
    SystemConfigFixtures.seed_embedding_config(%{model: "configured-model", dimension: 16})
    :ok
  end

  test "preserves arbitrary text and reports provider model and vector size for a single input" do
    text = " café\n"
    embedding = vector(0.1)
    Req.Test.expect(Client, &respond(&1, text, embedding, "provider-model"))

    assert {:ok,
            %{
              results: [
                %{
                  index: 1,
                  status: "ok",
                  model: "provider-model",
                  dimension: 16,
                  vector: ^embedding
                }
              ]
            } =
              output} = execute(%{"text" => text})

    assert {:ok, _} = GenerateEmbeddings.validate_output(output)
    refute Repo.exists?(Document)
    refute Repo.exists?(IngestJob)
  end

  test "preserves repeated inputs, including enriched text, and their positions" do
    assert {:ok, %{chunks: [%{embedding_input: enriched, content: raw}]}} =
             Jido.Exec.run(ChunkContent, %{content: "# Région\n\nCafé"}, %{})

    refute enriched == raw

    for {text, value} <- [{enriched, 0.1}, {"same", 0.2}, {"same", 0.3}] do
      Req.Test.expect(Client, &respond(&1, text, vector(value)))
    end

    assert {:ok, %{results: results}} = execute(%{texts: [enriched, "same", "same"]})

    assert Enum.map(results, &{&1.index, hd(&1.vector), &1.model}) ==
             [
               {1, 0.1, "configured-model"},
               {2, 0.2, "configured-model"},
               {3, 0.3, "configured-model"}
             ]
  end

  test "reports invalid provider responses and status without leaking provider details" do
    malformed = [
      %{"data" => []},
      %{"data" => [%{"embedding" => vector(0.1), "index" => 1}]},
      %{"data" => [%{"embedding" => vector(0.1)}, %{"embedding" => vector(0.2)}]},
      %{"data" => [%{"embedding" => ["not numeric" | tl(vector(0.1))]}]},
      %{"data" => [%{"embedding" => vector(0.1)}], "model" => nil}
    ]

    for body <- malformed do
      Req.Test.expect(Client, &Req.Test.json(&1, body))
    end

    Req.Test.expect(Client, &respond(&1, "short vector", [0.1]))

    Req.Test.expect(Client, fn conn ->
      conn
      |> put_status(401)
      |> Req.Test.json(%{"error" => "raw document and secret marker"})
    end)

    Req.Test.expect(Client, &respond(&1, "valid", vector(1)))

    log =
      capture_log(fn ->
        texts =
          List.duplicate("malformed", length(malformed)) ++ ["short vector", "private", "valid"]

        assert {:ok, %{results: results} = output} = execute(%{texts: texts})
        assert {:ok, _} = GenerateEmbeddings.validate_output(output)

        assert Enum.map(results, & &1.index) == Enum.to_list(1..8)

        assert Enum.map(Enum.take(results, 5), & &1.error) ==
                 List.duplicate("invalid_response", 5)

        assert [
                 %{status: "error", error: "invalid_dimension"},
                 %{status: "error", error: "provider_error", http_status: 401},
                 %{status: "ok", vector: [1 | _]}
               ] = Enum.drop(results, 5)

        refute Jason.encode!(output) =~ "secret marker"
      end)

    refute log =~ "secret marker"
  end

  test "returns the retry delay and leaves later inputs unattempted after rate limiting" do
    Req.Test.expect(Client, &respond(&1, "first", vector(0.4)))

    Req.Test.expect(Client, fn conn ->
      assert input(conn) == "second"

      conn
      |> put_resp_header("retry-after", "17")
      |> put_status(429)
      |> Req.Test.json(%{"error" => "busy"})
    end)

    assert {:ok,
            %{
              results: [
                %{index: 1, status: "ok"},
                %{index: 2, status: "error", error: "rate_limited", retry_after_seconds: 17},
                %{
                  index: 3,
                  status: "not_attempted",
                  error: "rate_limited",
                  retry_after_seconds: 17
                }
              ]
            }} = execute(%{texts: ["first", "second", "third"]})
  end

  test "reports transport failure without exposing the error payload" do
    Req.Test.expect(Client, &Req.Test.transport_error(&1, :econnrefused))

    assert {:ok, %{results: [%{index: 1, status: "error", error: "transport_error"}]}} =
             execute(%{text: "private"})
  end

  test "rejects invalid arguments before provider I/O" do
    for params <- [
          %{},
          %{text: "one", texts: ["two"]},
          %{text: "  "},
          %{texts: []},
          %{texts: ["valid", ""]},
          %{texts: List.duplicate("text", 17)},
          %{text: String.duplicate("é", 32_769)}
        ] do
      assert {:error, _} = execute(params)
    end
  end

  defp execute(params), do: Jido.Exec.run(GenerateEmbeddings, params, %{})

  defp vector(value), do: List.duplicate(value, 16)

  defp respond(conn, text, embedding, model \\ nil) do
    assert input(conn) == text
    body = %{"data" => [%{"embedding" => embedding, "index" => 0}]}
    body = if is_binary(model), do: Map.put(body, "model", model), else: body
    Req.Test.json(conn, body)
  end

  defp input(conn) do
    {:ok, body, _conn} = read_body(conn)
    %{"model" => "configured-model", "input" => input} = Jason.decode!(body)
    input
  end
end
