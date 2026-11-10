defmodule Zaq.TestSupport.HTTPFixtureOptions do
  @moduledoc """
  Applies Req options only to one local fixture's origin and path prefix.

  Use only in synchronous tests: Req's plugin list is application configuration.
  Requests to other destinations keep their original options. The original
  configuration is restored at test exit, including an absent configuration.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  def configure(url, options, match_request? \\ fn _request -> true end) do
    %URI{scheme: "http", host: "127.0.0.1"} = fixture = URI.parse(url)
    previous = Application.fetch_env(:req, :default_options)

    plugin = fn request ->
      Req.Request.append_request_steps(request,
        fixture_options: fn request ->
          uri = request.url

          if {uri.scheme, uri.host, uri.port} == {fixture.scheme, fixture.host, fixture.port} and
               String.starts_with?(uri.path || "/", fixture.path || "/") and
               match_request?.(request) do
            Req.Request.merge_options(request, options)
          else
            request
          end
        end
      )
    end

    defaults = Req.default_options()
    Req.default_options(Keyword.update(defaults, :plugins, [plugin], &(&1 ++ [plugin])))

    on_exit(fn ->
      case previous do
        {:ok, defaults} -> Req.default_options(defaults)
        :error -> Application.delete_env(:req, :default_options)
      end
    end)
  end
end
