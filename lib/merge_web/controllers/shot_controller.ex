defmodule MergeWeb.ShotController do
  @moduledoc """
  Serves a screenshot named in an open merge request's body, read-only. Only a
  `.png` regular file under `/tmp` that some open body names is served, so the
  server never hands out files nobody put in front of the reviewer.
  """

  use MergeWeb, :controller

  alias Merge.{Body, MergeRequest}

  def show(conn, %{"path" => path}) do
    if allowed?(path) do
      conn
      |> put_resp_content_type("image/png", nil)
      |> put_resp_header("cache-control", "no-cache")
      |> send_file(200, path)
    else
      send_resp(conn, 404, "Not found")
    end
  end

  def show(conn, _params), do: send_resp(conn, 404, "Not found")

  defp allowed?(path) do
    String.starts_with?(path, "/tmp/") and Path.extname(path) == ".png" and
      Path.expand(path) == path and named?(path) and regular?(path)
  end

  defp named?(path) do
    Enum.any?(MergeRequest.list(), &(path in Body.image_paths(&1.body)))
  end

  # Not a symlink, so a named path can't lead anywhere else.
  defp regular?(path), do: match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
end
