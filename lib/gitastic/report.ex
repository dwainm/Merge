defmodule Gitastic.Report do
  @moduledoc """
  Plain text for agents: what `gitastic mr wait` prints, and the MCP tools return.
  """

  @doc """
  The news of a wait as the text an agent reads as its next prompt: COMMENT for
  new comments, APPROVED or NEEDS WORK for a decision (with the comments since
  the agent last heard), CONFLICTS when the branch no longer merges cleanly
  into main (also added to the others), or the merge request closing. `via` is `:cli` or
  `:mcp`, for the hint on what to do next.
  """
  def outcome(o, url, via \\ :cli)

  def outcome(%{kind: :closed, merged: %{} = m} = o, url, _via) do
    where = if m.pushed, do: "On origin.", else: "Merged into main, not pushed yet."
    "MERGED #{m.short}: #{o.branch}\n#{url}\n\n#{m.short} #{m.subject}\n#{where}\n"
  end

  def outcome(%{kind: :closed} = o, _url, _via) do
    "Merge request #{o.branch} was #{o.status}.\n"
  end

  def outcome(%{kind: :conflicts} = o, url, via) do
    IO.iodata_to_binary([
      "CONFLICTS: #{o.branch}\n",
      if(url, do: "#{url}\n", else: []),
      conflicts(o.conflicts, via),
      listen(o.branch, via)
    ])
  end

  def outcome(%{kind: :comment} = o, url, via) do
    heading = if length(o.comments) == 1, do: "COMMENT", else: "#{length(o.comments)} COMMENTS"

    IO.iodata_to_binary([
      "#{heading}: #{o.branch}\n",
      if(url, do: "#{url}\n", else: []),
      "\n",
      Enum.map(o.comments, &comment/1),
      conflicts(o[:conflicts], via),
      listen(o.branch, via)
    ])
  end

  def outcome(%{kind: :decision} = o, url, via) do
    d = o.decision

    headline =
      case d.verdict do
        :approved -> "APPROVED: #{o.branch} at #{short(d.head)}"
        :needs_work -> "NEEDS WORK: #{o.branch} at #{short(d.head)}"
      end

    [
      headline,
      "\n",
      if(url, do: "#{url}\n", else: []),
      d.body != "" && "\n#{d.by}: #{d.body}\n",
      o.comments != [] &&
        ["\nComments since you last heard:\n" | Enum.map(o.comments, &comment/1)],
      o[:conflicts] && conflicts(o.conflicts, via),
      d.verdict == :needs_work && next_step(o.branch, via),
      listen(o.branch, via)
    ]
    |> Enum.filter(& &1)
    |> IO.iodata_to_binary()
  end

  defp next_step(branch, :cli) do
    "\nWhen it is fixed: gitastic mr addressed #{branch} <commit> --note \"...\"\n"
  end

  defp next_step(branch, :mcp) do
    "\nWhen it is fixed: call addressed with branch #{branch}, the commit and a note.\n"
  end

  defp conflicts(nil, _via), do: []

  defp conflicts(c, via) do
    commit = if via == :cli, do: "commit; the merge request picks it up by itself", else: "commit"

    [
      "\nMerging #{short(c.head)} into #{c.into} (#{short(c.target)}) conflicts in:\n",
      Enum.map(c.files, &"- #{&1}\n"),
      "Merge #{c.into} into the branch, resolve them and #{commit}.\n"
    ]
  end

  defp listen(branch, :cli), do: "\nKeep listening: gitastic mr wait #{branch}\n"
  defp listen(_branch, :mcp), do: "\nKeep listening: call wait_for_review again.\n"

  defp comment(c) do
    where =
      cond do
        c.path && c.line -> "#{c.path}:#{c.line}#{if c.side == "old", do: " (old)", else: ""}"
        c.path -> c.path
        true -> "general"
      end

    at = if c.commit, do: " in #{short(c.commit)}", else: ""
    body = String.replace(c.body, "\n", "\n    ")
    "- [#{where}#{at}] #{c.author}: #{body}\n"
  end

  defp short(nil), do: "?"
  defp short(sha), do: String.slice(sha, 0, 7)
end
