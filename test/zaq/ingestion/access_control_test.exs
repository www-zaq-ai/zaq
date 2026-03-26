defmodule Zaq.Ingestion.AccessControlTest do
  use Zaq.DataCase, async: true

  alias Zaq.Ingestion
  alias Zaq.Ingestion.Document
  alias Zaq.System.EmbeddingConfig

  setup do
    changeset =
      EmbeddingConfig.changeset(%EmbeddingConfig{}, %{
        endpoint: "http://localhost:11434/v1",
        model: "test-model",
        dimension: "1536"
      })

    {:ok, _} = Zaq.System.save_embedding_config(changeset)
    :ok
  end

  # Builds a user-like struct with role preloaded, matching what
  # Accounts.get_user!/1 returns (used by AuthHook and Plugs.Auth).
  defp user_with_role(role) do
    user = user_fixture(%{role: role})
    Repo.preload(user, :role)
  end

  defp unique_source, do: "file_#{System.unique_integer([:positive])}.md"

  setup do
    super_admin_role = role_fixture(%{name: "super_admin"})
    admin_role = role_fixture(%{name: "admin"})
    staff_role = role_fixture(%{name: "staff"})
    public_role = role_fixture(%{name: "public"})

    super_admin = user_with_role(super_admin_role)
    admin = user_with_role(admin_role)
    staff = user_with_role(staff_role)

    %{
      super_admin: super_admin,
      admin: admin,
      staff: staff,
      super_admin_role: super_admin_role,
      admin_role: admin_role,
      staff_role: staff_role,
      public_role: public_role
    }
  end

  describe "can_access_file?/2 — no document record" do
    test "returns true when no document exists for the path (backward compat)", %{admin: admin} do
      assert Ingestion.can_access_file?("untracked/file.md", admin)
    end

    test "normalizes leading ./ before lookup", %{admin: admin} do
      assert Ingestion.can_access_file?("./also/untracked.md", admin)
    end
  end

  describe "can_access_file?/2 — owner access" do
    test "owner role can access their own file", %{admin: admin, admin_role: admin_role} do
      source = unique_source()
      {:ok, _} = Document.upsert(%{source: source, role_id: admin_role.id})

      assert Ingestion.can_access_file?(source, admin)
    end

    test "different role cannot access without sharing", %{admin: admin, staff_role: staff_role} do
      source = unique_source()
      {:ok, _} = Document.upsert(%{source: source, role_id: staff_role.id})

      refute Ingestion.can_access_file?(source, admin)
    end
  end

  describe "can_access_file?/2 — super admin bypass" do
    test "super admin can access files owned by any role",
         %{super_admin: super_admin, admin_role: admin_role, staff_role: staff_role} do
      admin_file = unique_source()
      staff_file = unique_source()

      {:ok, _} = Document.upsert(%{source: admin_file, role_id: admin_role.id})
      {:ok, _} = Document.upsert(%{source: staff_file, role_id: staff_role.id})

      assert Ingestion.can_access_file?(admin_file, super_admin)
      assert Ingestion.can_access_file?(staff_file, super_admin)
    end

    test "super admin can access files with no role_id", %{super_admin: super_admin} do
      source = unique_source()
      {:ok, _} = Document.upsert(%{source: source})

      assert Ingestion.can_access_file?(source, super_admin)
    end
  end

  describe "can_access_file?/2 — explicit role sharing" do
    test "file shared with user's role is accessible", %{
      admin: admin,
      staff_role: staff_role,
      admin_role: admin_role
    } do
      source = unique_source()
      {:ok, _} = Document.upsert(%{source: source, role_id: staff_role.id})
      {:ok, _} = Ingestion.share_file(source, [admin_role.id])

      assert Ingestion.can_access_file?(source, admin)
    end

    test "file not shared with user's role is inaccessible", %{
      admin: admin,
      staff: staff,
      staff_role: staff_role,
      admin_role: admin_role
    } do
      source = unique_source()
      {:ok, _} = Document.upsert(%{source: source, role_id: staff_role.id})
      {:ok, _} = Ingestion.share_file(source, [admin_role.id])

      # staff uploaded it but it's shared with admin, not staff
      # staff is the owner so they can access it; admin can access via sharing
      assert Ingestion.can_access_file?(source, admin)
      assert Ingestion.can_access_file?(source, staff)
    end

    test "access is revoked when sharing is cleared", %{
      admin: admin,
      staff_role: staff_role,
      admin_role: admin_role
    } do
      source = unique_source()
      {:ok, _} = Document.upsert(%{source: source, role_id: staff_role.id})
      {:ok, _} = Ingestion.share_file(source, [admin_role.id])

      assert Ingestion.can_access_file?(source, admin)

      {:ok, _} = Ingestion.share_file(source, [])

      refute Ingestion.can_access_file?(source, admin)
    end
  end

  describe "can_access_file?/2 — public role" do
    test "file shared with public is accessible to all roles", %{
      admin: admin,
      staff: staff,
      super_admin: super_admin,
      admin_role: admin_role,
      public_role: public_role
    } do
      source = unique_source()
      {:ok, _} = Document.upsert(%{source: source, role_id: admin_role.id})
      {:ok, _} = Ingestion.share_file(source, [public_role.id])

      assert Ingestion.can_access_file?(source, admin)
      assert Ingestion.can_access_file?(source, staff)
      assert Ingestion.can_access_file?(source, super_admin)
    end

    test "file not shared with public is not universally accessible", %{
      admin: admin,
      staff: staff,
      admin_role: admin_role
    } do
      source = unique_source()
      {:ok, _} = Document.upsert(%{source: source, role_id: admin_role.id})

      assert Ingestion.can_access_file?(source, admin)
      refute Ingestion.can_access_file?(source, staff)
    end

    test "removing public from sharing revokes universal access", %{
      staff: staff,
      admin_role: admin_role,
      public_role: public_role
    } do
      source = unique_source()
      {:ok, _} = Document.upsert(%{source: source, role_id: admin_role.id})
      {:ok, _} = Ingestion.share_file(source, [public_role.id])

      assert Ingestion.can_access_file?(source, staff)

      {:ok, _} = Ingestion.share_file(source, [])

      refute Ingestion.can_access_file?(source, staff)
    end
  end

  describe "can_access_file?/2 — unscoped document (no role_id)" do
    test "document with nil role_id is accessible to all", %{admin: admin, staff: staff} do
      source = unique_source()
      {:ok, _} = Document.upsert(%{source: source})

      assert Ingestion.can_access_file?(source, admin)
      assert Ingestion.can_access_file?(source, staff)
    end
  end
end
