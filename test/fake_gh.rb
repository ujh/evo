require 'json'
require 'open3'
require 'tmpdir'

# Runs a script from scripts/ against a fake `gh` placed first on PATH.
#
# - `gh pr view PR --json number ...` prints 7.
# - `gh pr view PR --json headRefOid,statusCheckRollup` prints the next of
#   the given views and repeats the last one. A String view is printed as
#   is. With no views it fails, the way gh does for an unknown PR.
# - `gh pr checks` succeeds at once.
# - `gh api [--paginate] PATH --jq FILTER` runs FILTER over the fixture
#   given for the last two segments of PATH ("pulls/reviews",
#   "pulls/comments", "issues/comments"), or over [] if there is none.
module FakeGh
  SCRIPT = <<~'SH'.freeze
    #!/bin/sh
    set -eu
    dir=$(dirname "$0")
    case "$1 $2" in
      'pr view')
        case "$*" in
          *'--json number'*) echo 7; exit 0 ;;
        esac
        [ -f "$dir/view.0.json" ] || { echo 'GraphQL: Could not resolve to a PullRequest' >&2; exit 1; }
        n=$(cat "$dir/count" 2>/dev/null || echo 0)
        [ -f "$dir/view.$n.json" ] || n=$((n - 1))
        echo $((n + 1)) > "$dir/count"
        cat "$dir/view.$n.json"
        ;;
      'pr checks') exit 0 ;;
      'api --paginate'|'api repos'*)
        [ "$2" = '--paginate' ] && shift
        path=$2
        filter=$4
        kind=$(printf '%s' "$path" | awk -F/ '{ print $(NF - 2) "_" $NF }')
        if [ -f "$dir/api_$kind.json" ]; then cat "$dir/api_$kind.json"; else echo '[]'; fi | jq -r "$filter"
        ;;
      *) echo "unexpected gh call: $*" >&2; exit 2 ;;
    esac
  SH

  # Returns [stdout, stderr, exit status].
  def run_with_fake_gh(script, *args, views: [], api: {}, env: {})
    Dir.mktmpdir('evo-fake-gh') do |dir|
      gh = File.join(dir, 'gh')
      File.write(gh, SCRIPT)
      File.chmod(0o755, gh)
      views.each_with_index do |view, i|
        File.write(File.join(dir, "view.#{i}.json"), view.is_a?(String) ? view : JSON.generate(view))
      end
      api.each { |kind, items| File.write(File.join(dir, "api_#{kind}.json"), JSON.generate(items)) }
      path = File.expand_path("../scripts/#{script}", __dir__)
      out, err, status = Open3.capture3(env.merge('PATH' => "#{dir}:#{ENV.fetch('PATH')}"), 'sh', path, *args)
      [out, err, status.exitstatus]
    end
  end
end
