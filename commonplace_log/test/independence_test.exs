defmodule Commonplace.Log.IndependenceTest do
  @moduledoc """
  Verifies that paths read outside `commonplace_log/` stay within the shared,
  language-neutral protocol corpus in `conformance/` or the specification text
  in `docs/`.

  Behavioural evidence: with `worker/` absent, the full suite passed at 128
  tests on 2026-08-22. Naming other implementations in comments is expected
  and encouraged: this test constrains what the code READS, not what the
  documentation SAYS.
  """
  use ExUnit.Case, async: true

  @project_dir Path.dirname(__DIR__)
  @source_globs ["lib/**/*.ex", "test/**/*.{ex,exs}"]

  defp within?(path, directory) do
    path == directory or String.starts_with?(path, directory <> "/")
  end

  defp path_calls(source) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk([], fn
      {{:., _, [{:__aliases__, _, [:Path]}, function]}, _, arguments} = node, paths
      when function in [:expand, :join] ->
        literals =
          arguments
          |> Macro.prewalk([], fn
            literal, acc when is_binary(literal) -> {literal, [literal | acc]}
            child, acc -> {child, acc}
          end)
          |> elem(1)
          |> Enum.filter(&(".." in Path.split(&1)))

        {node, literals ++ paths}

      node, paths ->
        {node, paths}
    end)
    |> elem(1)
  end

  defp escaping_paths do
    @source_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.flat_map(fn source_path ->
      source = File.read!(source_path)

      for literal <- path_calls(source),
          resolved = Path.expand(literal, Path.dirname(source_path)),
          not within?(resolved, @project_dir) do
        %{source: source_path, literal: literal, resolved: resolved}
      end
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.source, &1.literal})
  end

  test "outbound source paths target only the shared corpus or specification" do
    paths = escaping_paths()

    control_literal = Enum.join(["..", "..", "conformance", "canonical-json"], "/")

    assert Enum.any?(
             paths,
             &(&1.source == "test/jcs_test.exs" and &1.literal == control_literal)
           ),
           "positive control failed: source scan did not find the JCS corpus path"

    assert length(paths) >= 4,
           "anti-vacuity floor failed: expected at least four escaping paths, found #{length(paths)}"

    workspace_dir = Path.dirname(@project_dir)

    allowed_roots =
      Enum.map(["conformance", "docs"], &Path.join(workspace_dir, &1))

    rejected =
      Enum.reject(paths, fn %{resolved: resolved} ->
        Enum.any?(allowed_roots, &within?(resolved, &1))
      end)

    assert rejected == [],
           "paths escaped commonplace_log/ outside the allowlist:\n#{inspect(rejected, pretty: true)}"
  end
end
