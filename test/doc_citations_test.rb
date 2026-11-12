require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'

# scripts/doc-citations.rb lists every citation of doc content in a
# repository's tracked files and fails when one does not resolve, so a
# change that moves or cuts doc text cannot silently break one.
class DocCitationsTest < Minitest::Test
  SCRIPT = File.expand_path('../scripts/doc-citations.rb', __dir__)

  def in_repo(files)
    Dir.mktmpdir('doc-citations') do |dir|
      files.each do |path, text|
        FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
        File.write(File.join(dir, path), text)
      end
      system('git', 'init', '-q', dir, exception: true)
      system('git', '-C', dir, 'add', '.', exception: true)
      out, status = Open3.capture2e(RbConfig.ruby, SCRIPT, chdir: dir)
      yield out, status
    end
  end

  # A doc with headings, numbered steps, and a numbered section, which the
  # other files cite in every supported way.
  TARGET = <<~MD.freeze
    # Guide

    ## Fixed workloads (`small`)

    ## Steps

    1. Plan.
    2. Build.

    ## 3. Noise
  MD

  def test_citations_that_resolve_pass_and_are_listed
    citing = <<~MD
      See [the workloads](docs/guide.md#fixed-workloads-small) and [steps](#local).
      `docs/guide.md`, "Fixed workloads" holds them; `docs/guide.md` section 3 explains noise.
      ## Local
    MD
    in_repo('docs/guide.md' => TARGET, 'NOTES.md' => citing,
            'docs/pull-requests.md' => "# PRs\n\n1. Fetch.\n2. Test.\n",
            'run.sh' => "# see docs/pull-requests.md step 2 and the docs\n") do |out, status|
      assert status.success?, out
      assert_match(/^ok\s+link\s+NOTES\.md:1\s+docs\/guide\.md#fixed-workloads-small$/, out)
      assert_match(/^ok\s+link\s+NOTES\.md:1\s+#local$/, out)
      assert_match(/^ok\s+section\s+NOTES\.md:2\s+docs\/guide\.md "Fixed workloads"$/, out)
      assert_match(/^ok\s+number\s+NOTES\.md:2\s+docs\/guide\.md section 3$/, out)
      assert_match(/^ok\s+step\s+run\.sh:1\s+docs\/pull-requests\.md step 2$/, out)
      assert_match(/^read\s+contract\s+run\.sh:1\s+# see docs\/pull-requests\.md step 2 and the docs$/, out)
      assert_match(/^5 citations checked, 0 broken; 1 code lines to read\.$/, out)
    end
  end

  def test_each_kind_of_broken_citation_fails
    citing = <<~MD
      [gone](docs/guide.md#missing) and [no file](docs/none.md).
      `docs/guide.md`, "Renamed section" and `docs/guide.md` section 4.
    MD
    in_repo('docs/guide.md' => TARGET, 'NOTES.md' => citing,
            'docs/pull-requests.md' => "# PRs\n\n1. Fetch.\n",
            'docs/orchestration.md' => "# Workflow\n\n### 1. Agree\n",
            'run.sh' => "# docs/pull-requests.md step 7, docs/orchestration.md step 5\n") do |out, status|
      refute status.success?, out
      assert_match(/^FAIL\s+link\s+NOTES\.md:1\s+docs\/guide\.md#missing$/, out)
      assert_match(/^FAIL\s+link\s+NOTES\.md:1\s+docs\/none\.md$/, out)
      assert_match(/^FAIL\s+section\s+NOTES\.md:2\s+docs\/guide\.md "Renamed section"$/, out)
      assert_match(/^FAIL\s+number\s+NOTES\.md:2\s+docs\/guide\.md section 4$/, out)
      assert_match(/^FAIL\s+step\s+run\.sh:1\s+docs\/pull-requests\.md step 7$/, out)
      assert_match(/^FAIL\s+step\s+run\.sh:1\s+docs\/orchestration\.md step 5$/, out)
      assert_match(/^6 citations checked, 6 broken; 1 code lines to read\.$/, out)
    end
  end

  # The repository's own docs: every citation resolves, so the PR workflow's
  # check (docs/pull-requests.md step 3) starts from a clean run.
  def test_the_repository_passes
    out, status = Open3.capture2e(RbConfig.ruby, SCRIPT, chdir: File.expand_path('..', __dir__))
    assert status.success?, out.lines.grep(/^FAIL/).join
  end

  # "section 1" names the heading numbered 1, not one numbered 10.
  def test_a_section_number_matches_whole
    in_repo('docs/guide.md' => "# Guide\n\n## 10. Ten\n", 'NOTES.md' => "`docs/guide.md` section 1\n") do |out, status|
      refute status.success?, out
      assert_match(/^FAIL\s+number\s+NOTES\.md:1\s+docs\/guide\.md section 1$/, out)
    end
  end

  # A heading inside a code block is no heading, and an external link is
  # not checked.
  def test_code_blocks_and_external_links_are_ignored
    target = "# Guide\n\n```\n## Not a heading\n```\n"
    citing = "[x](docs/guide.md#not-a-heading) [web](https://example.com/a.md#b)\n"
    in_repo('docs/guide.md' => target, 'NOTES.md' => citing) do |out, status|
      refute status.success?, out
      assert_match(/^FAIL\s+link\s+NOTES\.md:1\s+docs\/guide\.md#not-a-heading$/, out)
      refute_match(/example\.com/, out)
    end
  end
end
