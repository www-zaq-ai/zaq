defmodule Zaq.System.ReleaseUpdateTest do
  use Zaq.DataCase, async: false

  alias Zaq.System.ReleaseUpdate

  setup do
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

  test "returns :update_available when latest release is newer" do
    Req.Test.stub(HTTP, fn conn ->
      Req.Test.json(conn, %{"tag_name" => "v99.0.0"})
    end)

    assert :update_available = ReleaseUpdate.check_for_update()
  end

  test "returns :up_to_date when latest release matches current version" do
    current = :zaq |> Application.spec(:vsn) |> to_string()

    Req.Test.stub(HTTP, fn conn ->
      Req.Test.json(conn, %{"tag_name" => "v#{current}"})
    end)

    assert :up_to_date = ReleaseUpdate.check_for_update()
  end

  test "compares the supplied version rather than the executing pod version" do
    Req.Test.stub(HTTP, fn conn ->
      Req.Test.json(conn, %{"tag_name" => "v0.18.0"})
    end)

    assert :up_to_date = ReleaseUpdate.check_for_update("0.18.0")
    assert :update_available = ReleaseUpdate.check_for_update("0.17.0")
    assert :up_to_date = ReleaseUpdate.check_for_update("v0.19.0")
  end

  test "rejects invalid supplied versions without fetching a release" do
    Req.Test.stub(HTTP, fn _conn -> flunk("github should not be called") end)

    assert {:error, {:invalid_version, "invalid"}} = ReleaseUpdate.check_for_update("invalid")
  end

  test "returns error when github response is malformed" do
    Req.Test.stub(HTTP, fn conn ->
      Req.Test.json(conn, %{"name" => "latest"})
    end)

    assert {:error, {:unexpected_status, 200}} = ReleaseUpdate.check_for_update()
  end
end
