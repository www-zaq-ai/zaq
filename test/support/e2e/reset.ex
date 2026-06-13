defmodule Zaq.E2E.Reset do
  @moduledoc false

  # Per-describe reset invoked via POST /e2e/reset. The goal is to return the
  # E2E server to the state established by test/support/e2e/bootstrap.exs:
  #
  #   * System config rows wiped and re-seeded with a default embedding config
  #   * Ingestion tables empty, tmp/e2e_documents/ restored to the seed tree,
  #     seed files re-indexed so queries return known content
  #   * AI credentials wiped
  #   * Conversations/messages wiped, then the deterministic "E2E Unsupported
  #     Source Conversation" fixture is re-seeded (needed by Journey 4)
  #   * Persons/teams/channels wiped
  #   * ProcessorState back to 0 consecutive failures
  #
  # The bootstrap script is authoritative for content — this module reuses the
  # same fixtures rather than duplicating payload strings.

  alias Zaq.Accounts
  alias Zaq.Accounts.User
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.MCP.Endpoint, as: MCPEndpoint
  alias Zaq.E2E.DocumentProcessorFake
  alias Zaq.E2E.PortalState
  alias Zaq.E2E.ProcessorState
  alias Zaq.Engine.Conversations
  alias Zaq.Ingestion.{Chunk, Document, IngestChunkJob, IngestJob}
  alias Zaq.Repo
  alias Zaq.System.AIProviderCredential
  alias Zaq.System.Config, as: SystemConfig
  alias Zaq.SystemConfigFixtures
  alias Zaq.UserPortal.Provisioner

  @documents_root "tmp/e2e_documents"

  @seed_files [
    {"knowledge/benefits.md",
     """
     # Employee Benefits Handbook

     ZAQ offers health insurance, annual leave, and flexible working hours.
     Questions about benefits should mention the handbook and cite this document.
     """},
    {"knowledge/onboarding.md",
     """
     # New Hire Onboarding Guide

     Every new hire must complete onboarding in the first week and submit required forms.
     """},
    {"archive/retention.txt", "Retention policy documents stay available for seven years."}
  ]

  @doc "Run the full reset. Returns :ok on success, or raises on failure."
  def run do
    ProcessorState.reset()
    PortalState.reset()

    reset_filesystem!()
    reset_ingestion_tables!()
    reset_people_tables!()
    reset_conversations!()
    reset_users!()
    reset_system_config!()
    reseed_seed_files!()
    reseed_e2e_admin!()
    reseed_unsupported_source_conversation!()

    :ok
  end

  @doc """
  Seed the initial "admin" user that satisfies `bootstrap_admin_pending?/1`.

  Uses a single `Repo.insert!` — no subsequent update — so `inserted_at == updated_at`
  is preserved, which is the condition `GET /bo/bootstrap-login` checks before
  creating a session without a password.

  This mirrors the real first-run state: one user, username "admin", no email, no
  password hash, `must_change_password: true`.
  """
  def seed_bootstrap_admin! do
    # bootstrap_admin_pending_onboarding/0 returns nil if there are 2+ users,
    # so we must ensure "admin" is the only user. Reset.run() clears conversations
    # and messages first, so FK constraints on users are satisfied by this point.
    Repo.delete_all(User)

    role = Accounts.get_role_by_name("super_admin")

    Repo.insert!(%User{
      username: "admin",
      email: nil,
      role_id: role.id,
      must_change_password: true
    })
  end

  @doc """
  Seed (or replace) a user that is pending bootstrap onboarding.

  The user has a known password so it can authenticate at `/bo/login`, no email
  on file (so the change-password form prompts for one), and
  `must_change_password: true` so login redirects to `/bo/change-password` —
  the bootstrap onboarding flow under test. Idempotent: any existing user with
  the same username is removed first.

  Returns `{user, password}`.
  """
  def seed_onboarding_user!(attrs \\ %{}) do
    username = Map.get(attrs, "username", "e2e_onboard")
    password = Map.get(attrs, "password", "StrongPass1!")

    case Accounts.get_user_by_username(username) do
      %{} = existing -> Repo.delete!(existing)
      nil -> :ok
    end

    role = Accounts.get_role_by_name("super_admin")

    {:ok, user} =
      Accounts.create_user_with_password(%{
        username: username,
        email: "#{username}@seed.local",
        role_id: role.id,
        password: password
      })

    # create_user_with_password hashes the password but also clears
    # must_change_password. Force the pending-onboarding state and drop the seed
    # email so the change-password form prompts for a real one.
    {:ok, user} =
      user
      |> Ecto.Changeset.change(must_change_password: true, email: nil)
      |> Repo.update()

    {user, password}
  end

  @doc """
  Seed a user who has already completed bootstrap with `portal_consent="declined"`.
  Used for dashboard-retry scenarios (email conflict, etc.).

  Optional attrs:
    - "username" (default "e2e_declined_portal")
    - "password" (default "StrongPass1!")
    - "email"    (default nil — no email on file, triggering the email-input field)

  Returns `{user, password}`.
  """
  def seed_declined_portal_user!(attrs \\ %{}) do
    username = Map.get(attrs, "username", "e2e_declined_portal")
    password = Map.get(attrs, "password", "StrongPass1!")
    email = Map.get(attrs, "email")

    case Accounts.get_user_by_username(username) do
      %{} = existing -> Repo.delete!(existing)
      nil -> :ok
    end

    role = Accounts.get_role_by_name("super_admin")

    {:ok, user} =
      Accounts.create_user_with_password(%{
        username: username,
        email: email || "#{username}@seed.local",
        role_id: role.id,
        password: password
      })

    changes = [portal_consent: "declined", must_change_password: false]
    changes = if is_nil(email), do: [{:email, nil} | changes], else: changes

    {:ok, user} =
      user
      |> Ecto.Changeset.change(changes)
      |> Repo.update()

    # Scaffold the keyless ZAQ Router credential — mirrors what complete_bootstrap_onboarding
    # does on decline so dashboard-retry specs can assert the credential exists (keyless).
    Provisioner.ensure_offline_credential()

    {user, password}
  end

  @doc "Bump the mtime of a file inside the documents root, so stale detection fires."
  def touch_file!(relative_path) when is_binary(relative_path) do
    absolute = safe_path!(relative_path)
    # One minute in the future — beats any filesystem granularity.
    future = System.os_time(:second) + 60
    :ok = File.touch!(absolute, future)
    {:ok, absolute}
  end

  # ── Internals ──────────────────────────────────────────────────────────────

  # Delete all users except the standing E2E admin so bootstrap-created users
  # (e.g. the "admin" user seeded by seed_bootstrap_admin!) never leak across
  # describe blocks. Must run after reset_conversations! — messages FK users.
  defp reset_users! do
    e2e_admin = System.get_env("E2E_ADMIN_USERNAME", "e2e_admin")
    Repo.query!("DELETE FROM users WHERE username != $1", [e2e_admin])
  end

  # Re-create the E2E admin if seed_bootstrap_admin! wiped all users.
  # Other specs (ingestion, agents, etc.) log in as this user; it must exist
  # after every reset regardless of what bootstrap scenarios did to the table.
  defp reseed_e2e_admin! do
    username = System.get_env("E2E_ADMIN_USERNAME", "e2e_admin")
    password = System.get_env("E2E_ADMIN_PASSWORD", "StrongPass1!")

    unless Accounts.get_user_by_username(username) do
      role = Accounts.get_role_by_name("super_admin")

      {:ok, _} =
        Accounts.create_user_with_password(%{
          username: username,
          email: "#{username}@e2e.local",
          role_id: role.id,
          password: password
        })
    end
  end

  defp reset_filesystem! do
    root = Path.expand(@documents_root)
    File.rm_rf!(root)
    File.mkdir_p!(root)
    File.mkdir_p!(Path.join(root, "knowledge"))
    File.mkdir_p!(Path.join(root, "archive"))

    Enum.each(@seed_files, fn {relative, body} ->
      File.write!(Path.join(root, relative), body)
    end)
  end

  defp reset_ingestion_tables! do
    Repo.delete_all(IngestChunkJob)
    Repo.delete_all(Chunk)
    Repo.delete_all(Document)
    Repo.delete_all(IngestJob)
  end

  defp reset_people_tables! do
    # `channels` holds person↔channel mappings; FK cascades from people.
    Repo.query!("DELETE FROM channels", [])
    Repo.query!("DELETE FROM people", [])
    Repo.query!("DELETE FROM teams", [])
  end

  defp reset_conversations! do
    Repo.query!("DELETE FROM message_ratings", [])
    Repo.query!("DELETE FROM conversation_shares", [])
    Repo.query!("DELETE FROM messages", [])
    Repo.query!("DELETE FROM conversations", [])
  end

  defp reset_system_config! do
    Repo.delete_all(ConfiguredAgent)
    Repo.delete_all(MCPEndpoint)
    Repo.delete_all(SystemConfig)
    Repo.delete_all(AIProviderCredential)

    SystemConfigFixtures.seed_embedding_config(%{
      endpoint: System.get_env("EMBEDDING_ENDPOINT", "http://localhost:11434/v1"),
      model: System.get_env("EMBEDDING_MODEL", "bge-multilingual-gemma2"),
      dimension: parse_dim(System.get_env("EMBEDDING_DIMENSION", "3584"))
    })

    base_url = System.get_env("E2E_BASE_URL", "http://localhost:4002")

    SystemConfigFixtures.seed_llm_config(%{
      endpoint: "#{base_url}/e2e/llm/v1",
      model: "e2e-fake",
      api_key: "e2e-fake-key",
      supports_json_mode: false,
      supports_logprobs: false
    })
  end

  defp reseed_seed_files! do
    root = Path.expand(@documents_root)

    (Path.wildcard(Path.join(root, "**/*.md")) ++ Path.wildcard(Path.join(root, "**/*.txt")))
    |> Enum.each(fn source_path ->
      {:ok, _document} = DocumentProcessorFake.process_single_file(source_path)
    end)
  end

  defp reseed_unsupported_source_conversation! do
    admin_username = System.get_env("E2E_ADMIN_USERNAME", "e2e_admin")

    with %{} = admin_user <- Accounts.get_user_by_username(admin_username) do
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
    end
  end

  defp parse_dim(bin) when is_binary(bin) do
    case Integer.parse(bin) do
      {n, _} -> n
      :error -> 3584
    end
  end

  defp safe_path!(relative) do
    root = Path.expand(@documents_root)
    absolute = Path.expand(Path.join(root, relative))

    if String.starts_with?(absolute, root <> "/") or absolute == root do
      absolute
    else
      raise ArgumentError, "path escapes documents root: #{inspect(relative)}"
    end
  end
end
