defmodule ZaqWeb.Helpers.SizeFormatTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Helpers.SizeFormat

  test "formats nil and byte ranges" do
    assert SizeFormat.format_size(nil) == "—"
    assert SizeFormat.format_size(512) == "512 B"
    assert SizeFormat.format_size(2048) == "2.0 KB"
    assert SizeFormat.format_size(2_097_152) == "2.0 MB"
  end
end
