defmodule ZaqWeb.E2EController do
  @moduledoc false

  use ZaqWeb, :controller

  alias Zaq.Agent.MCP
  alias Zaq.E2E.{LogCollector, PortalState, ProcessorState, Reset}
  alias Zaq.Engine.Telemetry
  alias Zaq.System, as: SystemContext

  @e2e_enabled Application.compile_env(:zaq, :e2e, false)

  # Final safety net — routes compile away in prod, but this guards at action level too.
  def action(conn, _) do
    if @e2e_enabled do
      apply(__MODULE__, action_name(conn), [conn, conn.params])
    else
      conn |> put_status(:not_found) |> json(%{error: "not found"}) |> halt()
    end
  end

  # GET /e2e/processor/fail
  def fail(conn, params) do
    count = params |> Map.get("count", "1") |> String.to_integer()
    ProcessorState.set_fail(count)
    json(conn, %{ok: true, fail_count: count})
  end

  # GET /e2e/processor/reset
  def reset(conn, _params) do
    ProcessorState.reset()
    json(conn, %{ok: true})
  end

  # POST /e2e/reset — describe-level teardown. Truncates mutable tables and
  # re-seeds the deterministic fixtures bootstrap.exs creates.
  def reset_all(conn, _params) do
    :ok = Reset.run()
    json(conn, %{ok: true})
  end

  # POST /e2e/system-config with JSON body: {"key": "...", "value": "..."}
  def set_system_config(conn, params) do
    key = Map.get(params, "key")
    value = Map.get(params, "value")

    if is_binary(key) and key != "" do
      case Zaq.System.set_config(key, value) do
        {:ok, _} ->
          json(conn, %{ok: true, key: key, value: value})

        {:error, reason} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
      end
    else
      conn |> put_status(:bad_request) |> json(%{error: "missing key"})
    end
  end

  # POST /e2e/ai-credentials
  def create_ai_credential(conn, params) do
    case SystemContext.create_ai_provider_credential(params) do
      {:ok, credential} ->
        json(conn, %{
          ok: true,
          id: credential.id,
          name: credential.name,
          provider: credential.provider,
          endpoint: credential.endpoint
        })

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_ai_credential", details: inspect(changeset.errors)})
    end
  end

  # POST /e2e/agents
  def create_agent(conn, params) do
    alias Zaq.Agent

    case Agent.create_agent(params) do
      {:ok, agent} ->
        json(conn, %{
          ok: true,
          id: agent.id,
          name: agent.name,
          model: agent.model,
          credential_id: agent.credential_id
        })

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_agent", details: inspect(changeset.errors)})
    end
  end

  # POST /e2e/mcp-endpoints
  def create_mcp_endpoint(conn, params) do
    case MCP.create_mcp_endpoint(params) do
      {:ok, endpoint} ->
        json(conn, %{
          ok: true,
          id: endpoint.id,
          name: endpoint.name,
          status: endpoint.status
        })

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_mcp_endpoint", details: inspect(changeset.errors)})
    end
  end

  # POST /e2e/ingestion/touch_file?path=knowledge/benefits.md
  # Bumps the mtime of a file inside tmp/e2e_documents/ so stale detection
  # fires without Playwright having to sleep for filesystem granularity.
  def touch_file(conn, params) do
    case Map.get(params, "path") do
      path when is_binary(path) and path != "" ->
        {:ok, absolute} = Reset.touch_file!(path)
        json(conn, %{ok: true, path: absolute})

      _ ->
        conn |> put_status(:bad_request) |> json(%{error: "missing path"}) |> halt()
    end
  end

  # POST /e2e/bootstrap-admin — seed the initial "admin" user that satisfies
  # bootstrap_admin_pending?/1 (single insert, no password, inserted_at == updated_at).
  # After calling this, GET /bo/bootstrap-login creates a session and redirects to
  # /bo/change-password without requiring a password — matching the real first-run flow.
  def create_bootstrap_admin(conn, _params) do
    Reset.seed_bootstrap_admin!()
    json(conn, %{ok: true})
  end

  # POST /e2e/onboarding-user — seed (or replace) a user pending bootstrap
  # onboarding. Returns the credentials the spec uses to log in and drive the
  # /bo/change-password flow. Optional JSON body: {"username": ..., "password": ...}.
  def create_onboarding_user(conn, params) do
    {user, password} = Reset.seed_onboarding_user!(params)
    json(conn, %{ok: true, username: user.username, password: password})
  end

  # GET /e2e/portal/onboarding/:slug — loopback stub for
  # Zaq.UserPortal.Client.fetch_onboarding/1. Returns 503 when PortalState is
  # offline (the client treats any 5xx as :unavailable). Otherwise returns the
  # canned metadata shape the real portal produces.
  def portal_onboarding_metadata(conn, _params) do
    if PortalState.offline?() do
      conn |> put_status(503) |> json(%{"error" => "portal offline"})
    else
      json(conn, %{
        "status" => "ok",
        "message" => %{
          "message" => "Free credits activated — your ZAQ portal account is ready.",
          "offer_slug" => "free",
          "plan_status" => "enabled",
          "available" => true,
          "metadata" => %{
            "title" => "Activate your free credits",
            "body" => "To create your ZAQ account...",
            "accept_label" => "Accept & activate free credits",
            "decline_label" => "Decline — continue without free credits",
            "subtitle" => "Optional · You can skip this",
            "footnote" => "Free credits can be claimed later from the dashboard.",
            "banner_text" =>
              "Claim your $2 in free AI credits — activate your ZAQ portal account.",
            "post_accept" => %{
              "title" => "Activation email has been sent",
              "main_message" =>
                "Verify your email within 4 hours to keep using your free credits",
              "secondary_message" =>
                "You have the option to change your email address in your user account"
            }
          }
        }
      })
    end
  end

  # POST /e2e/portal/onboarding — loopback stub for Zaq.UserPortal.Client.onboard_user/1.
  #
  # Checks Zaq.E2E.PortalState for pre-registered conflicts (seed them via
  # POST /e2e/portal/conflicts before triggering the accept action in a spec).
  # Any unregistered input returns a canned success response.
  def portal_onboard(conn, params) do
    email = Map.get(params, "email")

    if is_binary(email) and PortalState.conflict_email?(email) do
      conn
      |> put_status(409)
      |> json(%{
        "error" => "email_already_registered",
        "message" => "A user with this email is already provisioned."
      })
    else
      json(conn, %{
        "status" => "ok",
        "user" => %{
          "litellm_api_key" => "sk-e2e-portal-key",
          "litellm_user_id" => "llm-user-e2e"
        }
      })
    end
  end

  # POST /e2e/portal/conflicts — seed conflict conditions before a spec step.
  # Body: {"email": "taken@example.com"}
  # Conflicts persist until POST /e2e/reset clears them.
  def register_portal_conflict(conn, params) do
    opts = maybe_put([], :email, Map.get(params, "email"))

    if opts == [] do
      conn |> put_status(:bad_request) |> json(%{error: "provide email"})
    else
      PortalState.register_conflict(opts)
      json(conn, %{ok: true, registered: Map.take(params, ["email"])})
    end
  end

  # POST /e2e/portal/offline — toggle the portal stub's offline mode.
  # Body: {"offline": true} or {"offline": false}.
  # When offline, portal_onboarding_metadata returns 503 (client treats as :unavailable).
  def set_portal_offline(conn, %{"offline" => offline}) when is_boolean(offline) do
    PortalState.set_offline(offline)
    json(conn, %{ok: true, offline: offline})
  end

  def set_portal_offline(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "provide {offline: true|false}"})
  end

  # POST /e2e/declined-portal-user — seed a user who completed bootstrap with
  # portal_consent="declined". Used for dashboard-retry scenarios (4, 5, 6).
  # Optional body: {"username": ..., "password": ..., "email": ...}
  # When "email" is omitted the user has no email (Scenario 5).
  # Returns {ok, username, password, user_id}.
  def create_declined_portal_user(conn, params) do
    {user, password} = Reset.seed_declined_portal_user!(params)
    json(conn, %{ok: true, username: user.username, password: password, user_id: user.id})
  end

  # GET /e2e/zaq-router-credential — returns whether the "ZAQ Router" AI
  # credential exists and whether it has an API key. Used by E2E specs to
  # assert provisioning state without clicking through the system config UI.
  def get_zaq_router_credential(conn, _params) do
    case SystemContext.get_ai_provider_credential_by_name("ZAQ Router") do
      nil ->
        conn |> put_status(:not_found) |> json(%{found: false, has_api_key: false})

      credential ->
        json(conn, %{
          found: true,
          has_api_key: is_binary(credential.api_key) and credential.api_key != ""
        })
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: Keyword.put(opts, key, val)

  # GET /e2e/health
  def health(conn, _params) do
    json(conn, %{
      status: "ok",
      env: "test",
      e2e: true,
      node: node()
    })
  end

  # GET /e2e/telemetry/points?metric=ingestion.*&limit=50&last_minutes=5
  def telemetry_points(conn, params) do
    points = Telemetry.list_recent_points(params)
    metric = Map.get(params, "metric", "")

    json(conn, %{
      points: Enum.map(points, &serialize_point/1),
      count: length(points),
      metric: metric
    })
  end

  # GET /e2e/logs/recent?level=error&limit=20
  def logs_recent(conn, params) do
    limit = params |> Map.get("limit", "100") |> parse_int(100)
    level = Map.get(params, "level", nil)

    opts = [limit: limit] ++ if(level, do: [level: level], else: [])
    logs = LogCollector.recent(opts)

    json(conn, %{
      logs: Enum.map(logs, &serialize_log/1),
      count: length(logs)
    })
  end

  # POST /e2e/llm/v1/chat/completions — fake OpenAI-compatible LLM endpoint.
  # Replaces the old LLMRunnerFake behaviour now that the agent pipeline uses
  # ReqLLM directly (Jido AI + ReqLLM) rather than the LLMRunnerBehaviour.
  #
  # Detects call type by system prompt content:
  #   - Retrieval prompt contains "positive_answer" → return JSON query struct
  #   - Answering prompt does not → return baseline/tuned text with source citation
  #
  # Jido AI's answering agent uses SSE streaming; retrieval uses regular JSON.
  # We detect via the "stream" field in the request body.
  def fake_llm(conn, _params) do
    messages = conn.body_params |> Map.get("messages", [])
    streaming? = conn.body_params |> Map.get("stream", false)

    system_content =
      messages |> Enum.find(%{}, &(Map.get(&1, "role") == "system")) |> Map.get("content", "")

    content = fake_llm_content(messages, system_content)

    if streaming? do
      fake_llm_stream(conn, content)
    else
      json(conn, %{
        "id" => "e2e-#{System.unique_integer([:positive])}",
        "object" => "chat.completion",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => content},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 20, "total_tokens" => 30}
      })
    end
  end

  defp fake_llm_content(messages, system_content) do
    if retrieval_call?(system_content) do
      user_content =
        messages |> Enum.find(%{}, &(Map.get(&1, "role") == "user")) |> Map.get("content", "")

      Jason.encode!(%{
        "query" => String.trim(user_content),
        "language" => "eng",
        "positive_answer" => "Searching your knowledge base...",
        "negative_answer" => "No relevant information found in your knowledge base."
      })
    else
      sources = extract_llm_sources(system_content)
      source = List.first(sources)
      tuned? = String.contains?(system_content, "E2E_PROMPT_VARIANT_B")

      body =
        if tuned?,
          do: "Tuned response generated from the updated prompt template.",
          else: "Baseline response generated from the default prompt template."

      if is_binary(source),
        do: "#{body} [[source:#{source}]]",
        else: "#{body} [[memory:llm-general-knowledge]]"
    end
  end

  defp fake_llm_stream(conn, content) do
    id = "e2e-#{System.unique_integer([:positive])}"

    chunks = [
      Jason.encode!(%{
        "id" => id,
        "object" => "chat.completion.chunk",
        "model" => "e2e-fake",
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{"role" => "assistant", "content" => ""},
            "finish_reason" => nil
          }
        ]
      }),
      Jason.encode!(%{
        "id" => id,
        "object" => "chat.completion.chunk",
        "model" => "e2e-fake",
        "choices" => [%{"index" => 0, "delta" => %{"content" => content}, "finish_reason" => nil}]
      }),
      Jason.encode!(%{
        "id" => id,
        "object" => "chat.completion.chunk",
        "model" => "e2e-fake",
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
      })
    ]

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    Enum.reduce(chunks, conn, fn chunk_json, conn ->
      {:ok, conn} = chunk(conn, "data: #{chunk_json}\n\n")
      conn
    end)
    |> then(fn conn ->
      {:ok, conn} = chunk(conn, "data: [DONE]\n\n")
      conn
    end)
  end

  defp retrieval_call?(system_content),
    do: String.contains?(system_content, "positive_answer")

  defp extract_llm_sources(system_content) do
    ~r/"source"\s*:\s*"([^"]+)"/
    |> Regex.scan(system_content, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp serialize_point(point) do
    %{
      metric_key: point.metric_key,
      value: point.value,
      occurred_at: DateTime.to_iso8601(point.occurred_at),
      dimensions: point.dimensions,
      source: point.source,
      node: point.node
    }
  end

  defp serialize_log(entry) do
    %{
      level: entry.level,
      message: entry.message,
      timestamp: DateTime.to_iso8601(entry.timestamp)
    }
  end

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(_, default), do: default
end
