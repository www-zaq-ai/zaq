defmodule ZaqWeb.Helpers.UploadFlash do
  @moduledoc """
  Flash messaging for the result of a batch file upload.

  Shared by every BO surface that consumes uploaded entries (ingestion, skill resources),
  so the four outcomes — all succeeded, partial, all failed, nothing consumed — read the
  same wherever a user uploads. Callers pass the noun and past-tense verb for their
  domain; the branching stays here.
  """

  import Phoenix.LiveView, only: [put_flash: 3]

  @doc """
  Adds the appropriate flash for an upload batch.

  `uploaded` and `failed` are the `{:ok, _}` / `{:error, reason}` halves of the
  `consume_uploaded_entries/3` results.

  ## Options

    * `:noun` — what was uploaded, singular (default `"file"`)
    * `:past_tense` — what happened to them (default `"uploaded"`)
  """
  def put_result(socket, uploaded, failed, opts \\ []) do
    noun = Keyword.get(opts, :noun, "file")
    past_tense = Keyword.get(opts, :past_tense, "uploaded")

    cond do
      uploaded != [] and failed == [] ->
        put_flash(socket, :info, "#{length(uploaded)} #{noun}(s) #{past_tense}.")

      uploaded != [] and failed != [] ->
        put_flash(
          socket,
          :info,
          "#{length(uploaded)} #{noun}(s) #{past_tense}. #{length(failed)} failed."
        )

      failed != [] ->
        put_flash(socket, :error, "Upload failed: #{reasons(failed)}")

      true ->
        socket
    end
  end

  defp reasons(failed) do
    failed
    |> Enum.map(fn {:error, reason} -> inspect(reason) end)
    |> Enum.uniq()
    |> Enum.join(", ")
  end
end
