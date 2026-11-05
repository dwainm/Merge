defmodule Merge.Checks.ExcerptTest do
  use ExUnit.Case, async: true

  alias Merge.Checks.Excerpt

  # The shape of main's check on 4 Nov 2026 (31a36a0): hex.audit failed at the top,
  # everything after it passed, and the tail was the test run's noise.
  @audit_failed """
  Resolving Hex dependencies...
  Unchanged:
    ecto 3.14.2 VULNERABLE!
  Found packages with security advisories, see above for details
  All dependencies have been fetched
  Advisories:
    ecto 3.14.2 - EEF-CVE-2026-118391 (HIGH)
      Unbounded query cache growth from interpolated JSON paths and splice lists in Ecto

  Found packages with security advisories
  Checking 632 source files (this might take a while) ...
  5263 mods/funs, found no issues.
  Running ExUnit with seed: 483819, max_cases: 32
  warning: variable "x" is unused
  07:32:15.772 [warning] Paystack refused /refund: A refund for this transaction is already in progress
  07:32:15.752 [error] Job failed: ** (Oban.PerformError) Insufficient balance
  Finished in 46.4 seconds (44.4s async, 2.0s sync)

  Result: 994 passed (4 doctests, 990 tests)
  """

  test "a failed audit shows the advisories, not the tests that ran after it" do
    excerpt = Excerpt.excerpt(@audit_failed)

    assert excerpt =~ ~r/\AAdvisories:/
    assert excerpt =~ "EEF-CVE-2026-118391"
    assert excerpt =~ ~r/Found packages with security advisories\z/
    refute excerpt =~ "Paystack"
    refute excerpt =~ "Result:"
  end

  test "a failed test shows the failures through the result" do
    log = """
    Checking 10 source files ...
    12 mods/funs, found no issues.
    Running ExUnit with seed: 1, max_cases: 32
    ...07:00:00.000 [warning] Paystack refused /refund
      1) test pays (Dop.PayTest)
         test/dop/pay_test.exs:12
         Assertion with == failed
    ..
    Finished in 1.0 seconds
    Result: 9 passed, 1 failed
    """

    excerpt = Excerpt.excerpt(log)
    assert excerpt =~ ~r/\A  1\) test pays/
    assert excerpt =~ ~r/Result: 9 passed, 1 failed\z/
    refute excerpt =~ "Paystack"
  end

  test "credo's issues, from its start to its summary" do
    log = """
    Found packages with security advisories, see above for details
    Checking 632 source files ...
    ┃ [R] ↗ Nested modules could be aliased at the top of the invoking module.
    ┃       lib/dop/x.ex:3:5 #(Dop.X.y)
    5263 mods/funs, found 1 refactoring opportunity.
    Result: 994 passed
    """

    assert Excerpt.excerpt(log) =~
             ~r/\AChecking 632 source files.*refactoring opportunity\.\z/s
  end

  test "a Mix error is the step that stopped: format's files" do
    log = """
    Advisories: none
    No advisories found
    ** (Mix) mix format failed due to --check-formatted.
    The following files are not formatted:

      * lib/dop/x.ex
    """

    assert Excerpt.excerpt(log) =~ ~r/\A\*\* \(Mix\) mix format failed.*lib\/dop\/x\.ex\z/s
  end

  test "the first step that failed wins, a long one keeps its start and its verdict" do
    failures = Enum.map_join(1..60, "\n", &"  #{&1}) test t#{&1} (T)")

    log = """
    Compiling 3 files (.ex)
    warning: unused
    Compilation failed due to warnings while using the --warnings-as-errors option
    #{failures}
    Result: 0 passed, 60 failed
    """

    assert Excerpt.excerpt(log) =~ ~r/\ACompiling 3 files.*--warnings-as-errors option\z/s

    long = Excerpt.excerpt("Running\n#{failures}\nResult: 0 passed, 60 failed\n")
    lines = String.split(long, "\n")
    assert length(lines) == 40
    assert hd(lines) == "  1) test t1 (T)"
    assert Enum.take(lines, -2) == ["…", "Result: 0 passed, 60 failed"]
  end

  test "without a step it knows, the last lines" do
    log = Enum.map_join(1..30, "\n", &"line #{&1}") <> "\nexit 1\n"
    excerpt = Excerpt.excerpt(log)

    assert excerpt |> String.split("\n") |> length() == 15
    assert excerpt =~ ~r/exit 1\z/
  end
end
