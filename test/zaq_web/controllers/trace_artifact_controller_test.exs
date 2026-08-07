defmodule ZaqWeb.TraceArtifactControllerTest do
  use ZaqWeb.ConnCase, async: false

  alias Zaq.Engine.Conversations

  import Zaq.AccountsFixtures

  defp store(attrs) do
    {:ok, artifact} =
      Conversations.create_trace_artifact(
        Map.merge(
          %{tool_call_id: "call_1", name: "photo.png", mime_type: "image/png", size: 8},
          attrs
        )
      )

    artifact
  end

  setup %{conn: conn} do
    user = user_fixture(%{username: "trace_artifact_admin"})
    {:ok, user} = Zaq.Accounts.change_password(user, %{password: "StrongPass1!"})

    {:ok, conn: init_test_session(conn, %{user_id: user.id})}
  end

  test "serves the stored bytes with the type they were read as", %{conn: conn} do
    artifact = store(%{content: "PNGBYTES"})

    conn = get(conn, ~p"/bo/trace-artifacts/#{artifact.id}")

    assert response(conn, 200) == "PNGBYTES"
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/png"
  end

  test "names the download after the file the provider sent", %{conn: conn} do
    artifact = store(%{content: "PNGBYTES"})

    conn = get(conn, ~p"/bo/trace-artifacts/#{artifact.id}")

    assert get_resp_header(conn, "content-disposition") |> hd() =~ "photo.png"
  end

  test "an artifact the provider never named still downloads", %{conn: conn} do
    artifact = store(%{content: "BYTES", name: nil})

    conn = get(conn, ~p"/bo/trace-artifacts/#{artifact.id}")

    assert get_resp_header(conn, "content-disposition") |> hd() =~ "attachment-#{artifact.id}"
  end

  test "an artifact with no declared type is served as octet-stream", %{conn: conn} do
    artifact = store(%{content: "BYTES", mime_type: nil})

    conn = get(conn, ~p"/bo/trace-artifacts/#{artifact.id}")

    assert get_resp_header(conn, "content-type") |> hd() =~ "application/octet-stream"
  end

  test "an oversized read kept as metadata has no bytes to serve", %{conn: conn} do
    artifact = store(%{content: nil, size: 40_000_000})

    conn = get(conn, ~p"/bo/trace-artifacts/#{artifact.id}")

    assert response(conn, 404)
  end

  test "an id that names nothing is a 404, not a crash", %{conn: conn} do
    conn = get(conn, ~p"/bo/trace-artifacts/#{Ecto.UUID.generate()}")

    assert response(conn, 404)
  end

  test "a malformed id is a 404 rather than an Ecto cast error", %{conn: conn} do
    conn = get(conn, ~p"/bo/trace-artifacts/not-a-uuid")

    assert response(conn, 404)
  end
end
