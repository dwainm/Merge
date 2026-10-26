defmodule Merge.ImagePaths do
  @moduledoc """
  Which changes make GitHub build the release image: the `pull_request.paths`
  of the repo's `.github/workflows/docker.yml`, read at the commit. A commit
  needs the image check when it changes one of them since it left
  `origin/main`. GitHub's globs: `*` within a directory, `**` across them.
  """

  alias Merge.Git

  @workflow ".github/workflows/docker.yml"

  @doc "True when `sha` changes a path the Docker workflow watches, against `origin/main`."
  def needed?(repo, sha) do
    with [_ | _] = patterns <- read(repo, sha),
         {:ok, changed} <- Git.changed_paths(repo, "origin/main", sha) do
      Enum.any?(changed, &watched?(patterns, &1))
    else
      _ -> false
    end
  end

  @doc "The watched paths in the workflow at `ref`; [] without one."
  def read(repo, ref) do
    case Git.cat(repo, ref, [@workflow]) do
      %{@workflow => yaml} -> parse(yaml)
      _ -> []
    end
  end

  @doc """
  The `paths` list under `on: pull_request:` of a workflow, by indentation:
  enough YAML for a list of quoted or bare strings. A `!` pattern is left out.
  """
  def parse(yaml) do
    yaml
    |> String.split("\n")
    |> Enum.map(&{indent(&1), String.trim(&1)})
    |> Enum.reject(fn {_, line} -> line == "" or String.starts_with?(line, "#") end)
    |> Enum.drop_while(fn {_, line} -> line != "pull_request:" end)
    |> section()
    |> Enum.drop_while(fn {_, line} -> line != "paths:" end)
    |> section()
    |> Enum.flat_map(fn
      {_, "- " <> item} -> [item |> String.trim() |> String.trim("\"") |> String.trim("'")]
      _ -> []
    end)
    |> Enum.reject(&String.starts_with?(&1, "!"))
  end

  # The lines indented under the first one.
  defp section([{at, _} | rest]), do: Enum.take_while(rest, fn {i, _} -> i > at end)
  defp section([]), do: []

  defp indent(line), do: byte_size(line) - byte_size(String.trim_leading(line))

  @doc "True when `path` matches one of the patterns."
  def watched?(patterns, path), do: Enum.any?(patterns, &Regex.match?(regex(&1), path))

  defp regex(pattern) do
    body =
      pattern
      |> String.split("**")
      |> Enum.map_join(".*", fn part ->
        part |> Regex.escape() |> String.replace("\\*", "[^/]*") |> String.replace("\\?", "[^/]")
      end)

    Regex.compile!("^" <> body <> "$")
  end
end
