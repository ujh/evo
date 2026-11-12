# Lists every citation of doc content in the repository's tracked files and
# whether it resolves; exits 1 if any does not. Run it from the repository
# root before and after a change that moves, renames, or cuts doc text
# (docs/pull-requests.md step 3):
#
#   mise exec -- ruby scripts/doc-citations.rb
#
# It checks:
#   link     Markdown links to a file and/or anchor in .md files
#   section  a doc file named with a quoted heading name: `docs/x.md`, "Name"
#   number   a doc file named with "section N" (a heading starting "N.")
#   step     "step N" of docs/pull-requests.md or docs/orchestration.md
# and lists, as "read contract", code lines that mention the docs, for a
# reader to check by hand. A section cited by quoted name without its file
# is not seen.

EXCLUDED = %w[pcg-c/ docs/gtp/].freeze

def tracked(pattern = nil)
  `git ls-files #{pattern}`.split("\n").reject { |f| f.start_with?(*EXCLUDED) }
end

def headings(file)
  return [] unless File.file?(file)

  in_code = false
  File.readlines(file).filter_map do |line|
    in_code = !in_code if line.start_with?('```')
    next if in_code

    line[/\A#+\s+(.*)/, 1]&.strip
  end
end

# GitHub's anchor for a heading.
def slug(heading)
  heading.downcase.delete('`').gsub(/[^\p{Word}\- ]/u, '').tr(' ', '-')
end

def resolve_link(from, path)
  return from if path.empty?

  [File.join(File.dirname(from), path), path].map { |c| File.expand_path(c).delete_prefix("#{Dir.pwd}/") }
                                              .find { |c| File.exist?(c) }
end

def doc_path(name, docs)
  name = name.delete('`')
  File.exist?(name) ? name : docs.find { |f| File.basename(f) == File.basename(name) }
end

docs = tracked("'*.md'")
rows = []
broken = 0
check = lambda do |ok, kind, where, text|
  broken += 1 unless ok
  rows << format('%-4s %-8s %s  %s', ok ? 'ok' : 'FAIL', kind, where, text)
end

tracked.each do |file|
  next unless File.file?(file)

  text = File.read(file, encoding: 'UTF-8')
  next unless text.valid_encoding?

  text.each_line.with_index(1) do |line, number|
    where = "#{file}:#{number}"
    if file.end_with?('.md')
      line.scan(/\]\(([^)\s#]*)(?:#([^)\s]+))?\)/) do |path, anchor|
        next if path.match?(%r{\A[a-z]+:}) || (path.empty? && anchor.nil?)

        target = resolve_link(file, path)
        ok = !target.nil? && (anchor.nil? || headings(target).map { |h| slug(h) }.include?(anchor))
        check.call(ok, 'link', where, anchor ? "#{path}##{anchor}" : path)
      end
    end
    line.scan(/`?((?:docs\/)?[A-Za-z_-]+\.md)`?,? \(?"([^"]{3,100})"/) do |name, section|
      target = doc_path(name, docs)
      ok = !target.nil? && headings(target).any? { |h| h.delete('`').start_with?(section.delete('`')) }
      check.call(ok, 'section', where, "#{name} \"#{section}\"")
    end
    line.scan(/`?((?:docs\/)?[A-Za-z_-]+\.md)`?,? sections? ([0-9][0-9.]*[0-9]|[0-9])/) do |name, section|
      target = doc_path(name, docs)
      ok = !target.nil? && headings(target).any? { |h| h.start_with?("#{section}. ", "#{section} ") }
      check.call(ok, 'number', where, "#{name} section #{section}")
    end
    line.scan(/((?:docs\/)?(?:pull-requests|orchestration)\.md)`?,? \(?step ([0-9]+)/) do |name, step|
      target = doc_path(name, docs)
      ok = !target.nil? && if name.include?('pull-requests')
                             File.read(target).match?(/^#{step}\. /)
                           else
                             headings(target).any? { |h| h.start_with?("#{step}. ") }
                           end
      check.call(ok, 'step', where, "#{name} step #{step}")
    end
    next if file.end_with?('.md')

    if line.match?(/\b(the docs|documented|docs\/[a-z-]+\.md|PROJECT_NOTES|CLAUDE\.md)\b/)
      rows << format('%-4s %-8s %s  %s', 'read', 'contract', where, line.strip[0, 160])
    end
  end
end

puts rows
puts
checked = rows.count { |r| r.start_with?('ok', 'FAIL') }
puts "#{checked} citations checked, #{broken} broken; #{rows.count { |r| r.start_with?('read') }} code lines to read."
exit(broken.zero? ? 0 : 1)
