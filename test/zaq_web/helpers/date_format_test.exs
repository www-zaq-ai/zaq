defmodule ZaqWeb.Helpers.DateFormatTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Helpers.DateFormat

  describe "format_date/1" do
    test "returns dash for nil" do
      assert DateFormat.format_date(nil) == "—"
    end

    test "formats valid iso8601 string" do
      assert DateFormat.format_date("2026-03-13T14:05:00Z") == "March 13, 2026"
    end

    test "returns raw input when iso8601 string is invalid" do
      assert DateFormat.format_date("not-a-date") == "not-a-date"
    end

    test "formats DateTime and NaiveDateTime" do
      assert DateFormat.format_date(~U[2026-03-13 14:05:00Z]) == "March 13, 2026"
      assert DateFormat.format_date(~N[2026-03-13 14:05:00]) == "March 13, 2026"
    end
  end

  describe "format_datetime/1" do
    test "returns dash for nil" do
      assert DateFormat.format_datetime(nil) == "—"
    end

    test "formats DateTime and NaiveDateTime" do
      assert DateFormat.format_datetime(~U[2026-03-13 14:05:00Z]) == "2026-03-13 14:05"
      assert DateFormat.format_datetime(~N[2026-03-13 14:05:00]) == "2026-03-13 14:05"
    end
  end

  describe "format_time/1" do
    test "returns dash for nil" do
      assert DateFormat.format_time(nil) == "—"
    end

    test "formats DateTime and NaiveDateTime" do
      assert DateFormat.format_time(~U[2026-03-13 14:05:00Z]) == "14:05"
      assert DateFormat.format_time(~N[2026-03-13 14:05:00]) == "14:05"
    end
  end

  describe "inject_date_separators/2" do
    test "empty list returns empty list" do
      assert DateFormat.inject_date_separators([]) == []
    end

    test "single message produces one leading separator" do
      msg = %{timestamp: ~U[2026-04-18 10:00:00Z]}

      assert [%{type: :date_separator, date: ~D[2026-04-18]}, ^msg] =
               DateFormat.inject_date_separators([msg])
    end

    test "two messages on same day produce one separator" do
      msg1 = %{timestamp: ~U[2026-04-18 09:00:00Z]}
      msg2 = %{timestamp: ~U[2026-04-18 15:00:00Z]}

      assert [%{type: :date_separator, date: ~D[2026-04-18]}, ^msg1, ^msg2] =
               DateFormat.inject_date_separators([msg1, msg2])
    end

    test "messages on different days produce one separator per day" do
      msg1 = %{timestamp: ~U[2026-04-17 10:00:00Z]}
      msg2 = %{timestamp: ~U[2026-04-18 10:00:00Z]}

      assert [
               %{type: :date_separator, date: ~D[2026-04-17]},
               ^msg1,
               %{type: :date_separator, date: ~D[2026-04-18]},
               ^msg2
             ] = DateFormat.inject_date_separators([msg1, msg2])
    end

    test "accepts custom key" do
      msg = %{inserted_at: ~U[2026-04-18 10:00:00Z]}

      assert [%{type: :date_separator, date: ~D[2026-04-18]}, ^msg] =
               DateFormat.inject_date_separators([msg], :inserted_at)
    end

    test "message with nil timestamp is passed through without separator" do
      msg = %{timestamp: nil}
      assert [^msg] = DateFormat.inject_date_separators([msg])
    end

    test "works with NaiveDateTime" do
      msg = %{timestamp: ~N[2026-04-18 10:00:00]}

      assert [%{type: :date_separator, date: ~D[2026-04-18]}, ^msg] =
               DateFormat.inject_date_separators([msg])
    end
  end

  describe "relative_date_label/1" do
    test "nil returns nil" do
      assert DateFormat.relative_date_label(nil) == nil
    end

    test "today returns Today" do
      assert DateFormat.relative_date_label(Date.utc_today()) == "Today"
    end

    test "yesterday returns Yesterday" do
      assert DateFormat.relative_date_label(Date.add(Date.utc_today(), -1)) == "Yesterday"
    end

    test "2 to 7 days ago returns Last week" do
      for days <- 2..7 do
        assert DateFormat.relative_date_label(Date.add(Date.utc_today(), -days)) == "Last week",
               "expected Last week for #{days} days ago"
      end
    end

    test "8 or more days ago returns formatted date string" do
      date = Date.add(Date.utc_today(), -8)
      label = DateFormat.relative_date_label(date)
      assert label == DateFormat.format_date(date)
      refute label in ["Today", "Yesterday", "Last week"]
    end
  end

  describe "inject_relative_date_separators/2" do
    test "empty list returns empty list" do
      assert DateFormat.inject_relative_date_separators([]) == []
    end

    test "items on same day produce one separator with relative label" do
      today = Date.utc_today()
      item1 = %{inserted_at: DateTime.new!(today, ~T[09:00:00], "Etc/UTC")}
      item2 = %{inserted_at: DateTime.new!(today, ~T[15:00:00], "Etc/UTC")}

      assert [%{type: :date_separator, label: "Today"}, ^item1, ^item2] =
               DateFormat.inject_relative_date_separators([item1, item2])
    end

    test "yesterday and today produce two separators in order" do
      today = Date.utc_today()
      yesterday = Date.add(today, -1)
      item1 = %{inserted_at: DateTime.new!(yesterday, ~T[10:00:00], "Etc/UTC")}
      item2 = %{inserted_at: DateTime.new!(today, ~T[10:00:00], "Etc/UTC")}

      assert [
               %{type: :date_separator, label: "Yesterday"},
               ^item1,
               %{type: :date_separator, label: "Today"},
               ^item2
             ] = DateFormat.inject_relative_date_separators([item1, item2])
    end

    test "items within last week share one Last week separator" do
      today = Date.utc_today()
      item1 = %{inserted_at: DateTime.new!(Date.add(today, -3), ~T[10:00:00], "Etc/UTC")}
      item2 = %{inserted_at: DateTime.new!(Date.add(today, -5), ~T[10:00:00], "Etc/UTC")}

      # items are ordered oldest first; both should be under one "Last week" separator
      [sep | rest] = DateFormat.inject_relative_date_separators([item2, item1])
      assert sep == %{type: :date_separator, label: "Last week"}
      assert length(rest) == 2
    end

    test "accepts custom key" do
      item = %{timestamp: DateTime.new!(Date.utc_today(), ~T[10:00:00], "Etc/UTC")}

      assert [%{type: :date_separator, label: "Today"}, ^item] =
               DateFormat.inject_relative_date_separators([item], :timestamp)
    end
  end
end
