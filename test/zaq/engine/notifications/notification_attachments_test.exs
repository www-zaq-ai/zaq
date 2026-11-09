defmodule Zaq.Engine.Notifications.NotificationAttachmentsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Engine.Notifications.Notification

  property "signed attachment metadata survives JSON serialization in order" do
    check all(ids <- uniq_list_of(string(:alphanumeric, min_length: 1), max_length: 5)) do
      records =
        Enum.map(ids, fn id ->
          {:ok, record} = Provenance.seal(%Record{id: id, kind: :file, name: "#{id}.txt"})
          record |> Record.metadata() |> Jason.encode!() |> Jason.decode!()
        end)

      assert {:ok, notification} =
               Notification.build(%{subject: "Files", body: "Attached", attachments: records})

      assert Enum.map(notification.attachments, & &1.id) == ids
      assert Enum.all?(notification.attachments, &match?({:ok, _}, Provenance.verify(&1)))
    end
  end

  property "a changed signed identity rejects the entire attachment collection" do
    check all(id <- string(:alphanumeric, min_length: 1)) do
      {:ok, record} = Provenance.seal(%Record{id: id, kind: :file})
      tampered = record |> Record.metadata() |> Map.put("id", id <> "-tampered")

      assert {:error, "attachments must contain signed file Records"} =
               Notification.build(%{
                 subject: "Files",
                 body: "Attached",
                 attachments: [record, tampered]
               })
    end
  end

  test "rejects malformed collections, unsigned files and non-file Records" do
    {:ok, folder} = Provenance.seal(%Record{id: "folder", kind: :folder})

    for invalid <- [
          nil,
          %{},
          [nil],
          [%Record{id: "unsigned", kind: :file}],
          [folder],
          List.duplicate(folder, 101)
        ] do
      assert {:error, _} =
               Notification.build(%{subject: "Files", body: "Attached", attachments: invalid})
    end
  end

  test "omitted attachments preserve text-only notifications" do
    assert {:ok, %{attachments: []}} = Notification.build(%{subject: "Hello", body: "Text"})
  end
end
