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

  test "returns error when github response is malformed" do
    Req.Test.stub(HTTP, fn conn ->
      Req.Test.json(conn, %{"name" => "latest"})
    end)

    assert {:error, {:unexpected_status, 200}} = ReleaseUpdate.check_for_update()
  end
end
