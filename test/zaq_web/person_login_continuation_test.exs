defmodule ZaqWeb.PersonLoginContinuationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ZaqWeb.PersonLoginContinuation

  @static_destinations ["/people/profile", "/people/credentials", "/people/history"]

  test "accepts only recognized People portal page destinations" do
    conversation_id = Ecto.UUID.generate()

    for destination <- @static_destinations ++ ["/people/conversations/#{conversation_id}"] do
      assert {:ok, ^destination} = PersonLoginContinuation.validate(destination)
    end

    for destination <- [
          nil,
          "",
          "/",
          "/people/login",
          "/people/session",
          "/people/challenge",
          "/people/credentials?return_to=/people/profile",
          "/people/profile#account",
          "/people/conversations/not-a-uuid",
          "/people/conversations//#{conversation_id}",
          "/people/conversations/#{String.upcase(conversation_id)}",
          "/people/conversations/#{conversation_id}/messages",
          "/bo/dashboard",
          "https://example.test/people/credentials",
          "//example.test/people/credentials",
          "\\\\example.test\\people\\credentials",
          "/%70eople/credentials",
          "/people/%63redentials",
          "/people/../bo/dashboard",
          "/people/credentials%00"
        ] do
      assert :error = PersonLoginContinuation.validate(destination)
    end
  end

  property "validation fails closed for arbitrary input" do
    check all(destination <- one_of([binary(), term()])) do
      case PersonLoginContinuation.validate(destination) do
        {:ok, accepted} ->
          assert accepted in @static_destinations or valid_conversation_path?(accepted)
          refute String.contains?(accepted, ["%", "?", "#", "\\"])

        :error ->
          :ok
      end
    end
  end

  property "canonical conversation UUID routes are accepted" do
    check all(raw_uuid <- binary(length: 16)) do
      uuid = Ecto.UUID.load!(raw_uuid)
      path = "/people/conversations/#{uuid}"
      assert {:ok, ^path} = PersonLoginContinuation.validate(path)
    end
  end

  defp valid_conversation_path?(path) do
    case String.split(path, "/", trim: true) do
      ["people", "conversations", id] -> match?({:ok, _}, Ecto.UUID.cast(id))
      _ -> false
    end
  end
end
