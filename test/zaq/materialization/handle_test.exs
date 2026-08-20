defmodule Zaq.Materialization.HandleTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Plug.Crypto.{KeyGenerator, MessageVerifier}
  alias Zaq.Materialization.Handle

  test "issues and verifies a JSON-safe handle" do
    assert {:ok, handle} =
             Handle.issue("data_source_document", %{
               "provider" => "google_drive",
               "file_id" => "f1"
             })

    assert {:ok,
            %{
              type: "data_source_document",
              locator: %{"provider" => "google_drive", "file_id" => "f1"},
              version: 1
            }} = Handle.verify(handle)
  end

  test "rejects tampered and malformed handles" do
    assert {:error, :invalid_materialization_handle} = Handle.verify("not-a-real-handle")

    assert {:ok, handle} = Handle.issue("data_source_document", %{"file_id" => "f1"})
    tampered = String.replace(handle, String.last(handle), "x")

    assert {:error, :invalid_materialization_handle} = Handle.verify(tampered)
  end

  test "rejects non-binary handles" do
    assert {:error, :invalid_materialization_handle} = Handle.verify(nil)
    assert {:error, :invalid_materialization_handle} = Handle.verify(%{})
  end

  test "rejects invalid payload fields" do
    assert {:error, :invalid_materialization_type} = Handle.issue(" ", %{})
    assert {:error, :invalid_materialization_handle} = Handle.issue("data_source_document", [])
  end

  test "rejects non-json-safe locators" do
    assert {:error, :invalid_materialization_locator} =
             Handle.issue("data_source_document", %{"pid" => self()})
  end

  test "rejects signed handles with unsupported versions" do
    handle =
      sign_payload(%{
        "v" => 2,
        "type" => "data_source_document",
        "locator" => %{"file_id" => "f1"}
      })

    assert {:error, :unsupported_materialization_handle} =
             Handle.verify(handle, secret_key_base: "test materialization secret")
  end

  test "rejects signed handles with invalid payload shape" do
    handle = sign_payload(%{"type" => "data_source_document"})

    assert {:error, :invalid_materialization_handle} =
             Handle.verify(handle, secret_key_base: "test materialization secret")
  end

  property "issued handles survive JSON round trips" do
    check all(
            provider <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
            file_id <- StreamData.string(:printable, min_length: 1, max_length: 30)
          ) do
      assert {:ok, handle} =
               Handle.issue("data_source_document", %{
                 "provider" => provider,
                 "file_id" => file_id
               })

      json_handle = handle |> Jason.encode!() |> Jason.decode!()

      assert {:ok, %{locator: %{"provider" => ^provider, "file_id" => ^file_id}}} =
               Handle.verify(json_handle)
    end
  end

  defp sign_payload(payload, secret_key_base \\ "test materialization secret") do
    secret = KeyGenerator.generate(secret_key_base, "zaq.materialization.handle")
    MessageVerifier.sign(Jason.encode!(payload), secret)
  end
end
