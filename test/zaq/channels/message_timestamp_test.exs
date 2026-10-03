defmodule Zaq.Channels.MessageTimestampTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.MessageTimestamp

  property "transport units describe the same instant" do
    check all(seconds <- integer(0..2_000_000_000)) do
      expected = DateTime.from_unix!(seconds)

      for {value, format} <- [
            {seconds, :second},
            {seconds * 1000, :millisecond},
            {DateTime.to_iso8601(expected), :iso8601}
          ] do
        assert DateTime.compare(MessageTimestamp.normalize(value, format), expected) == :eq
      end
    end
  end

  test "email dates retain their offset as an instant, invalid dates stay absent" do
    assert MessageTimestamp.normalize("Fri, 02 Oct 2026 12:00:00 +0200", :rfc2822) ==
             ~U[2026-10-02 10:00:00Z]

    for value <- [nil, %{}, "invalid", -999_999_999_999_999] do
      assert MessageTimestamp.normalize(value, :second) == nil
    end
  end
end
