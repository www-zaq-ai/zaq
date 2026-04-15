defmodule Zaq.SystemTest do
  use Zaq.DataCase, async: false

  alias Zaq.Ingestion.Chunk
  alias Zaq.System
  alias Zaq.System.EmbeddingConfig
  alias Zaq.System.ImageToTextConfig
  alias Zaq.System.LLMConfig
  alias Zaq.System.TelemetryConfig
  alias Zaq.Engine.Telemetry.Collector

  defp credential_fixture(attrs \\ %{}) do
    unique = :erlang.unique_integer([:positive])

    params =
      Map.merge(
        %{
          name: "Credential #{unique}",
          provider: "openai",
          endpoint: "https://api.openai.com/v1",
          sovereign: false
        },
        attrs
      )

    {:ok, credential} = System.create_ai_provider_credential(params)
    credential
  end

  describe "get_config/1 and set_config/2" do
    test "returns nil for unknown key" do
      assert is_nil(System.get_config("nonexistent.key"))
    end

    test "set_config/2 inserts a new key-value" do
      assert {:ok, _} = System.set_config("test.key", "hello")
      assert System.get_config("test.key") == "hello"
    end

    test "set_config/2 updates an existing key" do
      System.set_config("test.update", "first")
      assert {:ok, _} = System.set_config("test.update", "second")
      assert System.get_config("test.update") == "second"
    end

    test "set_config/2 coerces non-string values to string" do
      System.set_config("test.int", 42)
      assert System.get_config("test.int") == "42"
    end
  end

  # ── LLM ───────────────────────────────────────────────────────────────

  describe "get_llm_config/0" do
    test "returns LLMConfig defaults when no rows exist" do
      config = System.get_llm_config()
      assert %LLMConfig{} = config
      assert config.provider == "custom"
      assert config.model == "llama-3.3-70b-instruct"
      assert config.temperature == 0.0
      assert config.top_p == 0.9
      assert config.supports_logprobs == true
      assert config.supports_json_mode == true
    end

    test "returns stored values from DB" do
      System.set_config("llm.model", "gpt-4o")
      System.set_config("llm.endpoint", "https://api.openai.com/v1")
      System.set_config("llm.temperature", "0.7")
      System.set_config("llm.top_p", "0.8")
      System.set_config("llm.max_context_window", "8000")
      System.set_config("llm.distance_threshold", "1.0")

      config = System.get_llm_config()
      assert config.model == "gpt-4o"
      assert config.endpoint == "https://api.openai.com/v1"
      assert config.temperature == 0.7
      assert config.top_p == 0.8
      assert config.max_context_window == 8000
      assert config.distance_threshold == 1.0
    end

    test "keeps stored fallback connection fields when credential no longer exists" do
      System.set_config("llm.credential_id", 999_999)
      System.set_config("llm.provider", "fallback-provider")
      System.set_config("llm.endpoint", "https://fallback-llm.example/v1")
      System.set_config("llm.api_key", "")

      config = System.get_llm_config()
      assert config.credential_id == 999_999
      assert config.provider == "fallback-provider"
      assert config.endpoint == "https://fallback-llm.example/v1"
    end

    test "falls back to defaults for blank and invalid float values" do
      System.set_config("llm.temperature", "")
      System.set_config("llm.top_p", "not-a-number")

      config = System.get_llm_config()
      assert config.temperature == 0.0
      assert config.top_p == 0.9
    end
  end

  describe "save_llm_config/1" do
    test "persists valid changeset to DB" do
      credential = credential_fixture()

      changeset =
        LLMConfig.changeset(%LLMConfig{}, %{
          credential_id: credential.id,
          model: "gpt-4o",
          temperature: "0.5"
        })

      assert {:ok, saved} = System.save_llm_config(changeset)
      assert saved.model == "gpt-4o"
      assert saved.credential_id == credential.id
      assert saved.provider == "openai"
      assert saved.endpoint == "https://api.openai.com/v1"
      assert System.get_config("llm.model") == "gpt-4o"
      assert System.get_config("llm.credential_id") == Integer.to_string(credential.id)
    end

    test "returns merged connection fields from selected credential" do
      credential =
        credential_fixture(%{provider: "anthropic", endpoint: "https://api.anthropic.com/v1"})

      System.set_config("llm.credential_id", credential.id)
      System.set_config("llm.model", "claude-sonnet-4-20250514")

      config = System.get_llm_config()

      assert config.credential_id == credential.id
      assert config.provider == "anthropic"
      assert config.endpoint == "https://api.anthropic.com/v1"
    end

    test "returns error for invalid changeset" do
      changeset =
        LLMConfig.changeset(%LLMConfig{}, %{
          credential_id: nil,
          model: "",
          temperature: "5.0"
        })

      assert {:error, %Ecto.Changeset{valid?: false}} = System.save_llm_config(changeset)
    end
  end

  # ── Embedding ─────────────────────────────────────────────────────────

  describe "get_embedding_config/0" do
    test "returns EmbeddingConfig defaults when no rows exist" do
      config = System.get_embedding_config()
      assert %EmbeddingConfig{} = config
      assert config.provider == "custom"
      assert config.model == "bge-multilingual-gemma2"
      assert config.dimension == 3584
      assert config.chunk_min_tokens == 400
      assert config.chunk_max_tokens == 900
    end

    test "returns stored values from DB" do
      System.set_config("embedding.model", "text-embedding-ada-002")
      System.set_config("embedding.endpoint", "https://api.openai.com/v1")
      System.set_config("embedding.dimension", "1536")
      System.set_config("embedding.chunk_min_tokens", "300")
      System.set_config("embedding.chunk_max_tokens", "700")

      config = System.get_embedding_config()
      assert config.model == "text-embedding-ada-002"
      assert config.endpoint == "https://api.openai.com/v1"
      assert config.dimension == 1536
      assert config.chunk_min_tokens == 300
      assert config.chunk_max_tokens == 700
    end

    test "keeps stored fallback connection fields when credential no longer exists" do
      System.set_config("embedding.credential_id", 999_998)
      System.set_config("embedding.provider", "fallback-provider")
      System.set_config("embedding.endpoint", "https://fallback-embedding.example/v1")
      System.set_config("embedding.api_key", "")

      config = System.get_embedding_config()
      assert config.credential_id == 999_998
      assert config.provider == "fallback-provider"
      assert config.endpoint == "https://fallback-embedding.example/v1"
    end
  end

  describe "save_embedding_config/1" do
    test "persists valid changeset to DB" do
      credential = credential_fixture()

      changeset =
        EmbeddingConfig.changeset(%EmbeddingConfig{}, %{
          credential_id: credential.id,
          model: "bge-multilingual-gemma2",
          dimension: "768",
          chunk_min_tokens: "400",
          chunk_max_tokens: "900"
        })

      assert {:ok, saved} = System.save_embedding_config(changeset)
      assert saved.model == "bge-multilingual-gemma2"
      assert saved.credential_id == credential.id
      assert saved.provider == "openai"
      assert saved.endpoint == "https://api.openai.com/v1"
      assert System.get_config("embedding.model") == "bge-multilingual-gemma2"
      assert System.get_config("embedding.dimension") == "768"
      assert System.get_config("embedding.credential_id") == Integer.to_string(credential.id)
    end

    test "returns merged connection fields from selected credential" do
      credential =
        credential_fixture(%{provider: "openai", endpoint: "https://proxy.example.com/v1"})

      System.set_config("embedding.credential_id", credential.id)
      System.set_config("embedding.model", "text-embedding-3-large")
      System.set_config("embedding.dimension", "3072")

      config = System.get_embedding_config()

      assert config.credential_id == credential.id
      assert config.provider == "openai"
      assert config.endpoint == "https://proxy.example.com/v1"
    end

    test "returns error for invalid changeset" do
      changeset =
        EmbeddingConfig.changeset(%EmbeddingConfig{}, %{
          credential_id: nil,
          model: "",
          dimension: "0"
        })

      assert {:error, %Ecto.Changeset{valid?: false}} = System.save_embedding_config(changeset)
    end
  end

  # PostgreSQL DDL is transactional, so DROP/CREATE TABLE inside the sandbox
  # transaction is rolled back automatically at the end of each test.
  describe "save_embedding_config/1 chunk table lifecycle" do
    setup do
      prev_embedding = Application.get_env(:zaq, Zaq.Embedding.Client, [])

      on_exit(fn ->
        Application.put_env(:zaq, Zaq.Embedding.Client, prev_embedding)
      end)

      # Start each test with no chunks table — sandbox rollback restores it
      Chunk.drop_table()
      :ok
    end

    test "creates chunks table when embedding model is first configured" do
      credential = credential_fixture()

      refute Chunk.table_exists?()

      changeset =
        EmbeddingConfig.changeset(%EmbeddingConfig{}, %{
          credential_id: credential.id,
          model: "bge-multilingual-gemma2",
          dimension: "768"
        })

      assert {:ok, _} = System.save_embedding_config(changeset)
      assert Chunk.table_exists?()
    end

    test "does not reset chunks table when model is unchanged" do
      credential = credential_fixture()

      changeset =
        EmbeddingConfig.changeset(%EmbeddingConfig{}, %{
          credential_id: credential.id,
          model: "bge-multilingual-gemma2",
          dimension: "768"
        })

      {:ok, _} = System.save_embedding_config(changeset)
      assert Chunk.table_exists?()

      # Second save with same model — table not dropped/reset
      changeset2 =
        EmbeddingConfig.changeset(%EmbeddingConfig{}, %{
          credential_id: credential.id,
          model: "bge-multilingual-gemma2",
          dimension: "768",
          chunk_min_tokens: "500"
        })

      assert {:ok, saved} = System.save_embedding_config(changeset2)
      assert Chunk.table_exists?()
      assert saved.chunk_min_tokens == 500
    end

    test "drops and recreates chunks table when model changes" do
      credential = credential_fixture()

      changeset_a =
        EmbeddingConfig.changeset(%EmbeddingConfig{}, %{
          credential_id: credential.id,
          model: "bge-multilingual-gemma2",
          dimension: "768"
        })

      {:ok, _} = System.save_embedding_config(changeset_a)
      assert Chunk.table_exists?()
      assert System.get_config("embedding.model") == "bge-multilingual-gemma2"

      changeset_b =
        EmbeddingConfig.changeset(%EmbeddingConfig{}, %{
          credential_id: credential.id,
          model: "text-embedding-ada-002",
          dimension: "1536"
        })

      assert {:ok, saved} = System.save_embedding_config(changeset_b)
      assert Chunk.table_exists?()
      assert saved.model == "text-embedding-ada-002"
      assert saved.dimension == 1536
      assert System.get_config("embedding.model") == "text-embedding-ada-002"
    end
  end

  describe "embedding_ready?/0" do
    test "returns false when chunks table does not exist" do
      Chunk.drop_table()
      refute System.embedding_ready?()
    end

    test "returns true when chunks table exists" do
      Chunk.drop_table()
      Chunk.create_table(768)
      assert System.embedding_ready?()
    end
  end

  # ── Image to Text ──────────────────────────────────────────────────────

  describe "get_image_to_text_config/0" do
    test "returns ImageToTextConfig defaults when no rows exist" do
      config = System.get_image_to_text_config()
      assert %ImageToTextConfig{} = config
      assert config.provider == "custom"
      assert config.model == "pixtral-12b-2409"
      assert config.endpoint == "http://localhost:11434/v1"
    end

    test "returns stored values from DB" do
      System.set_config("image_to_text.model", "gpt-4o")
      System.set_config("image_to_text.endpoint", "https://api.openai.com/v1")

      config = System.get_image_to_text_config()
      assert config.model == "gpt-4o"
      assert config.endpoint == "https://api.openai.com/v1"
    end

    test "keeps stored fallback connection fields when credential no longer exists" do
      System.set_config("image_to_text.credential_id", 999_997)
      System.set_config("image_to_text.provider", "fallback-provider")
      System.set_config("image_to_text.endpoint", "https://fallback-vision.example/v1")
      System.set_config("image_to_text.api_key", "")

      config = System.get_image_to_text_config()
      assert config.credential_id == 999_997
      assert config.provider == "fallback-provider"
      assert config.endpoint == "https://fallback-vision.example/v1"
    end
  end

  describe "save_image_to_text_config/1" do
    test "persists valid changeset to DB" do
      credential = credential_fixture()

      changeset =
        ImageToTextConfig.changeset(%ImageToTextConfig{}, %{
          credential_id: credential.id,
          model: "gpt-4o"
        })

      assert {:ok, saved} = System.save_image_to_text_config(changeset)
      assert saved.model == "gpt-4o"
      assert saved.credential_id == credential.id
      assert saved.provider == "openai"
      assert saved.endpoint == "https://api.openai.com/v1"
      assert System.get_config("image_to_text.model") == "gpt-4o"
      assert System.get_config("image_to_text.credential_id") == Integer.to_string(credential.id)
    end

    test "returns merged connection fields from selected credential" do
      credential =
        credential_fixture(%{provider: "openai", endpoint: "https://vision.example.com/v1"})

      System.set_config("image_to_text.credential_id", credential.id)
      System.set_config("image_to_text.model", "gpt-4o")

      config = System.get_image_to_text_config()

      assert config.credential_id == credential.id
      assert config.provider == "openai"
      assert config.endpoint == "https://vision.example.com/v1"
    end

    test "returns error for invalid changeset" do
      # Start from a struct with nil required fields so validate_required fires
      changeset =
        ImageToTextConfig.changeset(
          struct(ImageToTextConfig, %{credential_id: nil, model: nil}),
          %{}
        )

      assert {:error, %Ecto.Changeset{valid?: false}} =
               System.save_image_to_text_config(changeset)
    end
  end

  describe "get_telemetry_config/0" do
    test "returns TelemetryConfig defaults when no rows exist" do
      config = System.get_telemetry_config()
      assert %TelemetryConfig{} = config
      assert config.capture_infra_metrics == false
      assert config.request_duration_threshold_ms == 10
      assert config.repo_query_duration_threshold_ms == 5
      assert config.no_answer_alert_threshold_percent == 10
      assert config.conversation_response_sla_ms == 1500
    end

    test "returns stored telemetry values from DB" do
      System.set_config("telemetry.capture_infra_metrics", "false")
      System.set_config("telemetry.request_duration_threshold_ms", "250")
      System.set_config("telemetry.repo_query_duration_threshold_ms", "15")
      System.set_config("telemetry.no_answer_alert_threshold_percent", "12")
      System.set_config("telemetry.conversation_response_sla_ms", "1800")

      config = System.get_telemetry_config()
      assert config.capture_infra_metrics == false
      assert config.request_duration_threshold_ms == 250
      assert config.repo_query_duration_threshold_ms == 15
      assert config.no_answer_alert_threshold_percent == 12
      assert config.conversation_response_sla_ms == 1800
    end
  end

  describe "save_telemetry_config/1" do
    test "persists valid telemetry changeset to DB" do
      changeset =
        TelemetryConfig.changeset(%TelemetryConfig{}, %{
          capture_infra_metrics: false,
          request_duration_threshold_ms: 500,
          repo_query_duration_threshold_ms: 30,
          no_answer_alert_threshold_percent: 14,
          conversation_response_sla_ms: 1700
        })

      assert {:ok, saved} = System.save_telemetry_config(changeset)
      assert saved.capture_infra_metrics == false
      assert saved.request_duration_threshold_ms == 500
      assert saved.repo_query_duration_threshold_ms == 30
      assert saved.no_answer_alert_threshold_percent == 14
      assert saved.conversation_response_sla_ms == 1700

      assert System.get_config("telemetry.capture_infra_metrics") == "false"
      assert System.get_config("telemetry.request_duration_threshold_ms") == "500"
      assert System.get_config("telemetry.repo_query_duration_threshold_ms") == "30"
      assert System.get_config("telemetry.no_answer_alert_threshold_percent") == "14"
      assert System.get_config("telemetry.conversation_response_sla_ms") == "1700"
    end

    test "returns error for invalid telemetry changeset" do
      changeset =
        TelemetryConfig.changeset(%TelemetryConfig{}, %{
          request_duration_threshold_ms: -1,
          repo_query_duration_threshold_ms: -10,
          no_answer_alert_threshold_percent: 101,
          conversation_response_sla_ms: -1
        })

      assert {:error, %Ecto.Changeset{valid?: false}} = System.save_telemetry_config(changeset)
    end

    test "reloads collector policy when collector process exists" do
      collector_pid = Process.whereis(Collector) || start_supervised!(Collector)
      assert is_pid(collector_pid)

      changeset =
        TelemetryConfig.changeset(%TelemetryConfig{}, %{
          capture_infra_metrics: true,
          request_duration_threshold_ms: 123,
          repo_query_duration_threshold_ms: 45,
          no_answer_alert_threshold_percent: 9,
          conversation_response_sla_ms: 987
        })

      assert {:ok, _} = System.save_telemetry_config(changeset)

      :sys.get_state(collector_pid)

      assert :persistent_term.get({Collector, :policy}) == %{
               capture_infra_metrics: true,
               request_duration_threshold_ms: 123,
               repo_query_duration_threshold_ms: 45
             }
    end
  end
end
