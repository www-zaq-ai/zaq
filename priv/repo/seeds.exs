alias Zaq.Repo
alias Zaq.Accounts.Role
alias Zaq.Agent.PromptTemplate

roles = ["super_admin", "admin", "staff"]

Enum.each(roles, fn name ->
  unless Repo.get_by(Role, name: name) do
    Repo.insert!(%Role{name: name, meta: %{}})
  end
end)

# Default prompt templates
templates = [
  %{
    slug: "retrieval",
    name: "Retrieval Agent",
    description: "Query rewriting prompt for the retrieval agent.",
    active: true,
    body: """
    You are a retrieval assistant. Your job is to rewrite the user's question into an optimal search query.

    Given the conversation history and the user's latest message, produce a single, self-contained search query that captures the user's intent clearly.

    Respond ONLY with a JSON object in this format:
    {"query": "<rewritten query>"}

    Do not add any explanation or extra text.
    """
  },
  %{
    slug: "answering",
    name: "Answering Agent",
    description: "Response generation prompt for the answering agent.",
    active: true,
    body: """
    You are a helpful assistant. Answer the user's question using ONLY the retrieved context provided below.

    Rules:
    - If the context does not contain enough information to answer, respond exactly with: NO_ANSWER
    - Do not make up information or use outside knowledge
    - Be concise and factual
    - Cite the source when possible

    Retrieved context:
    <%= retrieved_data %>

    User question: <%= question %>
    """
  },
  %{
    slug: "chunk_title",
    name: "Chunk Title Generator",
    description: "Generates a short descriptive title for a document chunk.",
    active: true,
    body: """
    You are a document indexing assistant. Given the following text chunk, generate a short, descriptive title (5-10 words) that summarizes its main topic.

    Respond ONLY with the title. No punctuation at the end. No quotes.

    Chunk:
    <%= chunk %>
    """
  }
]

Enum.each(templates, fn attrs ->
  unless Repo.get_by(PromptTemplate, slug: attrs.slug) do
    %PromptTemplate{}
    |> PromptTemplate.changeset(attrs)
    |> Repo.insert!()
  end
end)
