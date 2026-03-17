alias Zaq.Accounts
alias Zaq.Agent.PromptTemplate
alias Zaq.Ingestion.{Chunk, Document, IngestJob}
alias Zaq.Repo

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

IO.puts("[e2e-bootstrap] Ensuring admin user '#{username}'")

case Accounts.get_user_by_username(username) do
  nil ->
    {:ok, _user} =
      Accounts.create_user_with_password(%{
        username: username,
        role_id: admin_role.id,
        password: password
      })

  user ->
    {:ok, user} =
      Accounts.update_user(user, %{role_id: admin_role.id, must_change_password: false})

    {:ok, _user} = Accounts.change_password(user, %{password: password})
end

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
    Keep it concise and include [source: file] when data is present.

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

IO.puts("[e2e-bootstrap] Done")
