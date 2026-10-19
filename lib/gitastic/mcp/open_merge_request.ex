defmodule Gitastic.MCP.OpenMergeRequest do
  @moduledoc """
  Opens a merge request for a branch so a person can review it against its base
  (origin/main when the repo has it, else main). Opening registers you to hear
  the decision; call wait_for_review next.
  """

  use Anubis.Server.Component, type: :tool

  alias Gitastic.MergeRequest

  schema do
    field(:branch, {:required, :string}, description: "The branch to review")

    field(:repo, {:required, :string},
      description: "Absolute path of the repo or a worktree of it"
    )

    field(:base, :string, description: "The branch to review against, for a stacked branch")
    field(:title, :string, description: "A title; the branch name when left out")
    field(:body, :string, description: "What the branch does, for the reviewer")
    field(:as, :string, description: "Your name, shown to the reviewer")
  end

  @impl true
  def execute(params, frame) do
    case MergeRequest.open(%{
           branch: params.branch,
           repo: params.repo,
           base: params[:base],
           title: params[:title],
           body: params[:body],
           opened_by: params[:as]
         }) do
      {:ok, mr, how} ->
        verb = if how == :existing, do: "Already open", else: "Opened"

        Gitastic.MCP.reply(
          """
          #{verb}: #{mr.title} (#{mr.branch} → #{mr.base}, #{length(mr.commits)} commits, #{length(mr.files)} files)
          #{GitasticWeb.mr_url(mr.branch)}
          Call wait_for_review with branch #{mr.branch} to hear the decision.
          """,
          frame
        )

      {:error, reason} ->
        Gitastic.MCP.error(reason, frame)
    end
  end
end
