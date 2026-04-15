:logger.add_handler(:e2e_collector, Zaq.E2E.LogHandler, %{})

alias Zaq.Accounts
alias Zaq.Agent.PromptTemplate
alias Zaq.Engine.Conversations
alias Zaq.Engine.Telemetry
alias Zaq.Engine.Telemetry.Rollup
alias Zaq.Ingestion.{Chunk, Document, IngestJob}
alias Zaq.Repo
alias Zaq.SystemConfigFixtures

documents_root = Path.expand("tmp/e2e_documents")

IO.puts("[e2e-bootstrap] Resetting documents root: #{documents_root}")
File.rm_rf!(documents_root)
File.mkdir_p!(documents_root)
File.mkdir_p!(Path.join(documents_root, "knowledge"))
File.mkdir_p!(Path.join(documents_root, "archive"))

File.write!(
  Path.join(documents_root, "knowledge/benefits.md"),
  """
  # Employee Benefits Handbook

  ZAQ offers health insurance, annual leave, and flexible working hours.
  Questions about benefits should mention the handbook and cite this document.
  """
)

File.write!(
  Path.join(documents_root, "knowledge/onboarding.md"),
  """
  # New Hire Onboarding Guide

  Every new hire must complete onboarding in the first week and submit required forms.
  """
)

File.write!(
  Path.join(documents_root, "archive/retention.txt"),
  "Retention policy documents stay available for seven years."
)

IO.puts("[e2e-bootstrap] Ensuring embedding config and chunks table")

SystemConfigFixtures.seed_embedding_config(%{
  endpoint: System.get_env("EMBEDDING_ENDPOINT", "http://localhost:11434/v1"),
  model: System.get_env("EMBEDDING_MODEL", "bge-multilingual-gemma2"),
  dimension: System.get_env("EMBEDDING_DIMENSION", "3584")
})

IO.puts("[e2e-bootstrap] Cleaning ingestion tables")
Repo.delete_all(Chunk)
Repo.delete_all(Document)
Repo.delete_all(IngestJob)

seed_files =
  Path.wildcard(Path.join(documents_root, "**/*.md")) ++
    Path.wildcard(Path.join(documents_root, "**/*.txt"))

IO.puts("[e2e-bootstrap] Pre-indexing #{length(seed_files)} source files")

Enum.each(seed_files, fn source_path ->
  {:ok, _document} = Zaq.E2E.DocumentProcessorFake.process_single_file(source_path)
end)

ensure_role = fn role_name ->
  case Accounts.get_role_by_name(role_name) do
    nil ->
      {:ok, role} = Accounts.create_role(%{name: role_name, meta: %{}})
      role

    role ->
      role
  end
end

_ = ensure_role.("super_admin")
admin_role = ensure_role.("admin")
_ = ensure_role.("staff")

username = System.get_env("E2E_ADMIN_USERNAME", "e2e_admin")
password = System.get_env("E2E_ADMIN_PASSWORD", "StrongPass1!")
email = System.get_env("E2E_ADMIN_EMAIL", "e2e_admin@zaq.local")

IO.puts("[e2e-bootstrap] Ensuring admin user '#{username}'")

resolve_user_email = fn user ->
  if is_binary(user.email) and user.email != "", do: user.email, else: email
end

case Accounts.get_user_by_username(username) do
  nil ->
    {:ok, admin_user} =
      Accounts.create_user_with_password(%{
        username: username,
        email: email,
        role_id: admin_role.id,
        password: password
      })

    admin_user

  user ->
    {:ok, user} =
      Accounts.update_user(user, %{
        username: user.username || username,
        email: resolve_user_email.(user),
        role_id: admin_role.id,
        must_change_password: false
      })

    {:ok, _user} = Accounts.change_password(user, %{password: password})

    user
end
|> then(fn admin_user ->
  # Seed one deterministic conversation containing an unsupported source extension.
  # E2E verifies source chips are rendered but disabled for non-previewable types.
  {:ok, conv} =
    Conversations.create_conversation(%{
      title: "E2E Unsupported Source Conversation",
      user_id: admin_user.id,
      channel_user_id: "e2e_admin",
      channel_type: "bo"
    })

  {:ok, _} =
    Conversations.add_message(conv, %{
      role: "user",
      content: "Show me unsupported source behavior"
    })

  {:ok, _} =
    Conversations.add_message(conv, %{
      role: "assistant",
      content: "This answer references a binary source.",
      confidence_score: 0.9,
      sources: [%{"path" => "archive/evidence.bin"}]
    })
end)

templates = [
  %{
    slug: "retrieval",
    name: "Retrieval Agent",
    description: "E2E retrieval template",
    active: true,
    body: """
    Rewrite the user question as a concise search query.
    Return JSON with keys: query, language, positive_answer, negative_answer.
    """
  },
  %{
    slug: "answering",
    name: "Answering Agent",
    description: "E2E answering template",
    active: true,
    body: """
    Answer the user question using retrieved data only.
    Keep it concise and append [[source:<exact retrieved_data.source value>]] when data is present.
    For model prior knowledge (not in retrieved_data), append [[memory:llm-general-knowledge]].

    USER QUESTION: <%= @question %>
    retrieved_data = <%= @retrieved_data %>
    """
  },
  %{
    slug: "chunk_title",
    name: "Chunk Title Generator",
    description: "E2E chunk title template",
    active: true,
    body: "Generate a short title for: <%= chunk %>"
  }
]

IO.puts("[e2e-bootstrap] Ensuring prompt templates")

Enum.each(templates, fn attrs ->
  case PromptTemplate.get_by_slug(attrs.slug) do
    nil ->
      {:ok, _template} = PromptTemplate.create(attrs)

    template ->
      {:ok, _template} = PromptTemplate.update(template, attrs)
  end
end)

IO.puts("[e2e-bootstrap] Seeding telemetry rollups")

Repo.delete_all(Rollup)

now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

insert_rollup = fn metric_key, sum, count, opts ->
  source = Keyword.get(opts, :source, "local")
  bucket_start = Keyword.get(opts, :bucket_start, now)
  dimensions = Keyword.get(opts, :dimensions, %{})

  Repo.insert!(%Rollup{
    metric_key: metric_key,
    bucket_start: bucket_start,
    bucket_size: "10m",
    source: source,
    dimensions: dimensions,
    dimension_key: Telemetry.dimension_key(dimensions),
    value_sum: sum * 1.0,
    value_count: count,
    value_min: sum * 1.0,
    value_max: sum * 1.0,
    last_value: sum * 1.0,
    last_at: bucket_start
  })
end

# Core QA metrics — drive time series, gauge, radar, donut, bar
insert_rollup.("qa.message.count", 50.0, 50, [])
insert_rollup.("qa.answer.count", 45.0, 45, [])
insert_rollup.("qa.no_answer.count", 5.0, 5, [])
insert_rollup.("qa.answer.latency_ms", 3000.0, 10, [])
insert_rollup.("qa.answer.confidence", 0.88, 1, [])

# Feedback — drives gauge automation_score > 60 and donut segments
insert_rollup.("feedback.rating", 20.0, 20, [])
insert_rollup.("feedback.negative.count", 2.0, 2, [])

# Benchmark — drives the benchmark toggle assertions
insert_rollup.("qa.answer.latency_ms", 3500.0, 10, source: "benchmark")
insert_rollup.("feedback.rating", 18.0, 18, source: "benchmark")
insert_rollup.("feedback.negative.count", 4.0, 4, source: "benchmark")

IO.puts("[e2e-bootstrap] Done")
