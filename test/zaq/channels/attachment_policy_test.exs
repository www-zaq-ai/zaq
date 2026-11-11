defmodule Zaq.Channels.AttachmentPolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.DeliveryFiles
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Outgoing

  defmodule ConnectionResolver do
    def fetch_connection_details_for_config(config), do: config
  end

  property "Jido outbound resolution preserves connection details and resolves the connector policy" do
    check all(
            {setting, expected} <-
              member_of([
                {false, :abort},
                {"false", :abort},
                {true, :continue},
                {"true", :continue},
                {nil, :continue}
              ]),
            token <- string(:alphanumeric, min_length: 1),
            max_runs: 25
          ) do
      connection = %{
        url: "https://chat.example.test",
        token: token,
        settings: %{"send_on_file_failure" => setting},
        adapter_opts: [max_file_size: 1024]
      }

      assert {:ok, resolved} =
               JidoChatBridge.fetch_connection_details_for_config(connection,
                 outgoing: outgoing(),
                 connection_resolver: ConnectionResolver
               )

      assert resolved.attachment_failure_policy == expected
      assert Map.delete(resolved, :attachment_failure_policy) == connection
    end
  end

  test "Jido outbound resolution defaults to continue and retains an explicit resolved policy" do
    assert {:ok, %{attachment_failure_policy: :continue}} =
             JidoChatBridge.fetch_connection_details_for_config(%{},
               outgoing: outgoing(),
               connection_resolver: ConnectionResolver
             )

    connection = %{attachment_failure_policy: :abort, settings: %{"send_on_file_failure" => true}}

    assert {:ok, ^connection} =
             JidoChatBridge.fetch_connection_details_for_config(connection,
               outgoing: outgoing(),
               connection_resolver: ConnectionResolver
             )
  end

  test "continue prepares usable files and records safe failures in input order" do
    files = [
      file("first", "one"),
      file("bad", "%%%", %{"encoding" => "base64"}),
      file("last", "two")
    ]

    assert {:ok, prepared, [failure]} =
             DeliveryFiles.prepare(files, %{}, attachment_failure_policy: :continue)

    assert Enum.map(prepared, &{&1.attachment_index, &1.content}) == [{0, "one"}, {2, "two"}]
    assert failure.attachment_index == 1
    assert failure.stage == :preparation
    assert failure.delivery == :not_sent
    refute inspect(failure) =~ "%%%"
  end

  test "invalid explicit preparation policy fails before acquiring files" do
    assert {:error, {:invalid_attachment_failure_policy, :invalid}} =
             DeliveryFiles.prepare([file("bad", nil)], %{}, attachment_failure_policy: :invalid)
  end

  test "continue returns a known empty file selection after all preparations fail" do
    assert {:ok, [], [%{attachment_index: 0}]} =
             DeliveryFiles.prepare([file("bad", nil)], %{}, attachment_failure_policy: :continue)
  end

  test "abort preserves the original preparation error and absent policy remains compatible" do
    records = [file("ok", "ready"), file("bad", "%%%", %{"encoding" => "base64"})]

    assert {:error, :invalid_attachment_base64} =
             DeliveryFiles.prepare(records, %{}, attachment_failure_policy: :abort)

    assert {:error, :invalid_attachment_base64} = DeliveryFiles.prepare(records, %{})
  end

  property "continue preserves every usable byte, order and original index around failed files" do
    check all(bytes <- list_of(binary(max_length: 256), max_length: 10)) do
      records =
        Enum.flat_map(Enum.with_index(bytes), fn {content, index} ->
          [file("#{index}", content), file("invalid-#{index}", nil)]
        end)

      assert {:ok, prepared, failures} =
               DeliveryFiles.prepare(records, %{}, attachment_failure_policy: :continue)

      assert Enum.map(prepared, & &1.content) == bytes

      assert Enum.map(prepared, & &1.attachment_index) ==
               Enum.map(Enum.with_index(bytes), fn {_, index} -> index * 2 end)

      assert length(failures) == length(bytes)
    end
  end

  defp outgoing,
    do: %Outgoing{body: "Answer", channel_id: "room", provider: :mattermost}

  defp file(id, content, attributes \\ %{}),
    do: %Record{id: id, kind: :file, name: "#{id}.txt", content: content, attributes: attributes}
end
