# frozen_string_literal: true

require 'spec_helper'
require 'bundler'

# The Markdown files in the gem are read in three places: on GitHub, inside
# the installed gem, and (README.md, as the landing page) on rubydoc.info. A
# relative link works in all of them only if its target ships in the gem, and
# on rubydoc.info a relative link in the README never works: it resolves under
# rubydoc.info/gems/claude-agent-sdk/. No network access here: only the
# repository's own files are checked.
RSpec.describe 'links in the packaged Markdown files' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:packaged) { Bundler.load_gemspec_uncached(File.join(root, 'claude-agent-sdk.gemspec')).files }
  let(:markdown_files) { packaged.grep(/\.md\z/) }

  # Inline links and images, and reference definitions, outside fenced code,
  # each as { file:, line:, target: }.
  def links_in(file)
    links = []
    in_fence = false
    File.readlines(File.join(root, file), chomp: true).each_with_index do |line, index|
      in_fence = !in_fence if line.match?(/\A\s*```/)
      next if in_fence

      # Code spans can hold link-shaped text (`hash[key](arg)`); a link's own
      # text may be a code span, so the span is blanked, not removed.
      prose = line.gsub(/`[^`]*`/) { |span| 'x' * span.length }
      # The link text may hold one level of brackets: a linked badge is
      # [![alt](image)](target), and both targets count.
      targets = prose.scan(/!?\[(?:[^\]\[]|\[[^\]]*\])*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/).flatten +
                prose.scan(/\A\[[^\]]+\]:\s*(\S+)/).flatten
      targets.each { |target| links << { file: file, line: index + 1, target: target } }
    end
    links
  end

  def relative?(target)
    !target.match?(/\A(?:[a-z][a-z0-9+.-]*:|#)/i)
  end

  # The path a relative link resolves to, from the repository root.
  def resolve(link)
    path = link[:target].split('#', 2).first
    File.expand_path(path, File.dirname(File.join(root, link[:file]))).delete_prefix("#{root}/")
  end

  # GitHub's heading anchors: lowercase, punctuation dropped, spaces to
  # hyphens, a numeric suffix for a repeated heading.
  def anchors_in(file)
    seen = Hash.new(0)
    in_fence = false
    File.readlines(File.join(root, file), chomp: true).filter_map do |line|
      in_fence = !in_fence if line.match?(/\A\s*```/)
      next if in_fence || !(heading = line[/\A\#{1,6}\s+(.*?)\s*#*\z/, 1])

      text = heading.gsub(/\[([^\]]*)\]\([^)]*\)/, '\1').downcase
      slug = text.gsub(/[^\p{L}\p{N}\- _]/u, '').tr(' ', '-')
      seen[slug] += 1
      seen[slug] == 1 ? slug : "#{slug}-#{seen[slug] - 1}"
    end
  end

  def relative_links
    markdown_files.flat_map { |file| links_in(file) }.select { |link| relative?(link[:target]) }
  end

  it 'finds the Markdown files and their links' do
    expect(markdown_files).to include('README.md', 'CHANGELOG.md', 'docs/client.md')
    expect(markdown_files.flat_map { |file| links_in(file) }.size).to be > 100
  end

  it 'has no relative link or image in README.md, the rubydoc.info landing page' do
    relative = links_in('README.md').select { |link| relative?(link[:target]) }

    expect(relative.map { |link| "README.md:#{link[:line]} #{link[:target]}" }).to eq([])
  end

  it 'points every relative link at a file that ships in the gem' do
    unpackaged = relative_links.reject { |link| packaged.include?(resolve(link)) }

    expect(unpackaged.map { |link| "#{link[:file]}:#{link[:line]} #{link[:target]}" }).to eq([])
  end

  it 'points every anchor at a heading that exists' do
    links = markdown_files.flat_map { |file| links_in(file) }.select { |link| link[:target].include?('#') }
    broken = links.filter_map do |link|
      target = link[:target]
      next unless target.start_with?('#') || relative?(target)

      target_file = target.start_with?('#') ? link[:file] : resolve(link)
      next unless target_file.end_with?('.md') && File.file?(File.join(root, target_file))

      "#{link[:file]}:#{link[:line]} #{target}" unless anchors_in(target_file).include?(target.split('#', 2).last)
    end

    expect(broken).to eq([])
  end
end
