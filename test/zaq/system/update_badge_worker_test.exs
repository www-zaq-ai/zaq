defmodule Zaq.System.UpdateBadgeWorkerTest do
  use Zaq.DataCase, async: false

  import Ecto.Query

  alias Zaq.Repo
  alias Zaq.System
  alias Zaq.System.Config
  alias Zaq.System.ReleaseUpdate
  alias Zaq.System.UpdateBadgeWorker

  setup do
    Repo.delete_all(from c in Config, where: c.key == "ui.update_badge_enabled")

    original = Application.get_env(:zaq, ReleaseUpdate, [])

    Application.put_env(
      :zaq,
      ReleaseUpdate,
      Keyword.merge(original, plug: {Req.Test, __MODULE__.HTTP})
    )

    on_exit(fn -> Application.put_env(:zaq, ReleaseUpdate, original) end)
    :ok
  end

  defmodule HTTP do
  end

  test "cron execution skips check when badge is already enabled" do
    assert {:ok, _} = System.set_config("ui.update_badge_enabled", "true")

    Req.Test.stub(HTTP, fn _conn ->
      flunk("github should not be called when badge is already enabled")
    end)

    assert :ok = UpdateBadgeWorker.perform(%Oban.Job{args: %{}})
    assert "true" == System.get_config("ui.update_badge_enabled")
  end

  test "force execution checks and resets badge when current version is latest" do
    assert {:ok, _} = System.set_config("ui.update_badge_enabled", "true")
    current = :zaq |> Application.spec(:vsn) |> to_string()

    Req.Test.stub(HTTP, fn conn ->
      Req.Test.json(conn, %{"tag_name" => "v#{current}"})
    end)

    assert :ok = UpdateBadgeWorker.perform(%Oban.Job{args: %{"force" => true}})
    assert "false" == System.get_config("ui.update_badge_enabled")
  end

  test "enables badge when newer release is available" do
    assert {:ok, _} = System.set_config("ui.update_badge_enabled", "false")

    Req.Test.stub(HTTP, fn conn ->
      Req.Test.json(conn, %{"tag_name" => "v99.0.0"})
    end)

    assert :ok = UpdateBadgeWorker.perform(%Oban.Job{args: %{}})
    assert "true" == System.get_config("ui.update_badge_enabled")
  end

  test "returns error and preserves badge value on github failure" do
    assert {:ok, _} = System.set_config("ui.update_badge_enabled", "false")

    Req.Test.stub(HTTP, fn conn ->
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    assert {:error, {:unexpected_status, 500}} = UpdateBadgeWorker.perform(%Oban.Job{args: %{}})
    assert "false" == System.get_config("ui.update_badge_enabled")
  end
end
