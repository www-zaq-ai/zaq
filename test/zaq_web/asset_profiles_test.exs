defmodule ZaqWeb.AssetProfilesTest do
  use ExUnit.Case, async: true

  test "production builds cannot overwrite Storybook's preview stylesheet" do
    production = Application.fetch_env!(:tailwind, :zaq) |> Keyword.fetch!(:args)
    preview = Application.fetch_env!(:tailwind, :zaq_dev) |> Keyword.fetch!(:args)

    assert "--input=assets/css/app.css" in production
    assert "--input=assets/css/app.dev.css" in preview

    production_output = Enum.find(production, &String.starts_with?(&1, "--output="))
    preview_output = Enum.find(preview, &String.starts_with?(&1, "--output="))

    assert production_output == "--output=priv/static/assets/css/app.css"
    assert preview_output == "--output=priv/static/assets/css/app.dev.css"
    refute production_output == preview_output
  end
end
