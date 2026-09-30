# frozen_string_literal: true

# Keeps the CHANGELOG's [Unreleased] entry for CLIInstaller::PINNED_CLI_VERSION
# in step with the pin, for .github/workflows/cli-pin-bump.yml. Pin-only
# changes are batched into the next gem release rather than released one by
# one, so a run of bump PRs merged between releases must leave exactly one
# entry: "moves from <last released pin> to **<current pin>**".
#
#   ruby .github/scripts/pin_changelog.rb OLD_PIN NEW_PIN [CHANGELOG.md]
#
# Only the bold target version of an existing entry is rewritten, so prose a
# maintainer adds after it survives. Keep the "moves from X to **Y**" prefix
# intact when editing the entry: without it the next bump adds a second one. A bump back to the released pin removes the
# entry (and a `### Changed` heading it leaves empty).
module PinChangelog
  UNRELEASED = /^## \[Unreleased\][^\n]*\n/
  SECTION_END = /^## /
  ENTRY = /^- `CLIInstaller::PINNED_CLI_VERSION` moves from (\S+) to \*\*([^*]+)\*\*/
  # Keep a Changelog's subsection order; a new `### Changed` goes before the
  # first of these that the section already has.
  AFTER_CHANGED = /^### (Deprecated|Removed|Fixed|Security)\b/
  CLI_CHANGELOG = 'https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md'

  module_function

  def entry(from, to)
    "- `CLIInstaller::PINNED_CLI_VERSION` moves from #{from} to **#{to}**, " \
      'following the CLI the Python SDK bundles. `CLIInstaller.install_pinned` installs it. ' \
      "See the [Claude Code changelog](#{CLI_CHANGELOG}).\n"
  end

  def update(changelog, from:, to:)
    return changelog if from == to

    head = changelog.match(UNRELEASED) or raise ArgumentError, 'CHANGELOG has no ## [Unreleased] heading'
    body_start = head.end(0)
    body_end = changelog.index(SECTION_END, body_start) || changelog.length
    body = update_section(changelog[body_start...body_end], from: from, to: to)
    changelog[0...body_start] + body + changelog[body_end..]
  end

  def update_section(body, from:, to:)
    if (existing = body.match(ENTRY))
      released = existing[1]
      return drop_entry(body, existing) if to == released

      return body.sub(ENTRY) { "- `CLIInstaller::PINNED_CLI_VERSION` moves from #{released} to **#{to}**" }
    end

    insert_entry(body, entry(from, to))
  end

  def drop_entry(body, match)
    line_end = body.index("\n", match.begin(0)) || (body.length - 1)
    body = body[0...match.begin(0)] + body[(line_end + 1)..]
    # An emptied `### Changed` (only blank lines before the next heading or
    # the section's end) goes too.
    body.sub(/^### Changed\n\s*(?=^### |\z)/, '')
  end

  def insert_entry(body, line)
    lines = body.lines
    changed = lines.index("### Changed\n")
    if changed
      # After the subsection's last non-blank line.
      stop = ((changed + 1)...lines.length).find { |i| lines[i].start_with?('### ') } || lines.length
      last = (changed...stop).reverse_each.find { |i| !lines[i].strip.empty? }
      lines.insert(last + 1, line)
      return lines.join
    end

    block = "### Changed\n#{line}\n" # ends in the blank line before what follows
    at = lines.index { |l| l.match?(AFTER_CHANGED) }
    if at
      lines.insert(at, block)
      return lines.join
    end

    # Append at the section's end, keeping the blank line before the next
    # release heading.
    content = body.rstrip
    content.empty? ? "\n#{block}" : "#{content}\n\n#{block}"
  end
end

if $PROGRAM_NAME == __FILE__
  from, to, path = ARGV
  abort 'usage: pin_changelog.rb OLD_PIN NEW_PIN [CHANGELOG.md]' unless from && to

  path ||= 'CHANGELOG.md'
  File.write(path, PinChangelog.update(File.read(path), from: from, to: to))
end
