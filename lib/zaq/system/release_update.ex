defmodule Zaq.System.ReleaseUpdate do
  @moduledoc """
  Checks whether a newer ZAQ release exists on GitHub.
  """

  @latest_release_url "https://api.github.com/repos/www-zaq-ai/zaq/releases/latest"

  @spec check_for_update() :: :update_available | :up_to_date | {:error, term()}
  def check_for_update do
    with {:ok, current_version} <- current_version(),
         {:ok, latest_version} <- latest_version() do
      case Version.compare(current_version, latest_version) do
        :lt -> :update_available
        :eq -> :up_to_date
        :gt -> :up_to_date
      end
    end
  end

  defp current_version do
    :zaq
    |> Application.spec(:vsn)
    |> normalize_version()
  end

  defp latest_version do
    req_options = Application.get_env(:zaq, __MODULE__, [])

    case Req.get(@latest_release_url, req_options) do
      {:ok, %Req.Response{status: status, body: %{"tag_name" => tag}}} when status in 200..299 ->
        normalize_version(tag)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_version(nil), do: {:error, :missing_version}

  defp normalize_version(version) do
    normalized =
      version
      |> to_string()
      |> String.trim()
      |> String.trim_leading("v")

    case Version.parse(normalized) do
      {:ok, parsed} -> {:ok, to_string(parsed)}
      :error -> {:error, {:invalid_version, version}}
    end
  end
end
