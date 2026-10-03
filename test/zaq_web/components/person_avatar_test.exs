defmodule ZaqWeb.Components.PersonAvatarTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Phoenix.LiveViewTest
  alias ZaqWeb.Components.PersonAvatar

  property "a Person color is independent of labels and provider identities" do
    check all(id <- positive_integer()) do
      first =
        render_component(&PersonAvatar.avatar/1,
          name: "Alex Morgan",
          person_id: id,
          identity_key: "mattermost:a"
        )

      second =
        render_component(&PersonAvatar.avatar/1,
          name: "Alex M",
          person_id: id,
          identity_key: "slack:b"
        )

      assert [_, color] = Regex.run(~r/style="([^"]+)"/, first)
      assert [_, ^color] = Regex.run(~r/style="([^"]+)"/, second)
      assert first =~ "AM"
    end
  end
end
