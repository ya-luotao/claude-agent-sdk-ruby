# frozen_string_literal: true

require 'spec_helper'
require_relative '../../.github/scripts/pin_changelog'

# The CHANGELOG step of .github/workflows/cli-pin-bump.yml.
RSpec.describe PinChangelog do
  let(:released) { "## [1.1.0] - 2026-09-30\n\n### Changed\n- Released entry.\n" }
  let(:entry) { described_class.entry('2.1.285', '2.1.286') }

  # +unreleased+ is everything between the heading and the next release
  # heading, blank lines included, exactly as in CHANGELOG.md.
  def changelog(unreleased)
    "# Changelog\n\n## [Unreleased]\n#{unreleased}#{released}"
  end

  def unreleased_of(text)
    text[/^## \[Unreleased\]\n(.*?)^## \[1\.1\.0\]/m, 1]
  end

  def bump(unreleased, from: '2.1.285', to: '2.1.286')
    unreleased_of(described_class.update(changelog(unreleased), from: from, to: to))
  end

  it 'adds a Changed subsection to an empty [Unreleased]' do
    expect(bump("\n")).to eq("\n### Changed\n#{entry}\n")
  end

  it 'appends to an existing Changed subsection' do
    expect(bump("\n### Changed\n- Something else.\n\n### Fixed\n- A fix.\n\n"))
      .to eq("\n### Changed\n- Something else.\n#{entry}\n### Fixed\n- A fix.\n\n")
  end

  it 'puts a new Changed subsection after Added and before Fixed' do
    expect(bump("\n### Added\n- A feature.\n\n### Fixed\n- A fix.\n\n"))
      .to eq("\n### Added\n- A feature.\n\n### Changed\n#{entry}\n### Fixed\n- A fix.\n\n")
  end

  it 'appends a Changed subsection when no later subsection exists' do
    expect(bump("\n### Added\n- A feature.\n\n"))
      .to eq("\n### Added\n- A feature.\n\n### Changed\n#{entry}\n")
  end

  it 'moves only the target of an existing entry, keeping its released pin and any added prose' do
    result = bump("\n### Changed\n#{entry.chomp} It also fixes X.\n\n", from: '2.1.286', to: '2.1.287')

    expect(result).to eq("\n### Changed\n#{described_class.entry('2.1.285', '2.1.287').chomp} It also fixes X.\n\n")
  end

  it 'drops the entry, and a Changed heading it empties, on a bump back to the released pin' do
    expect(bump("\n### Added\n- A feature.\n\n### Changed\n#{entry}\n", from: '2.1.286', to: '2.1.285'))
      .to eq("\n### Added\n- A feature.\n\n")
  end

  it 'keeps a Changed heading that still has other entries when dropping the entry' do
    expect(bump("\n### Changed\n- Something else.\n#{entry}\n", from: '2.1.286', to: '2.1.285'))
      .to eq("\n### Changed\n- Something else.\n\n")
  end

  it 'leaves released sections alone' do
    result = described_class.update(changelog("\n"), from: '2.1.285', to: '2.1.286')

    expect(result).to end_with("\n#{released}")
  end

  it 'is a no-op when the pin did not move' do
    input = changelog("\n")

    expect(described_class.update(input, from: '2.1.285', to: '2.1.285')).to eq(input)
  end

  it 'fails loudly without an [Unreleased] heading' do
    expect { described_class.update("# Changelog\n", from: '1', to: '2') }
      .to raise_error(ArgumentError, /Unreleased/)
  end

  it 'handles the real CHANGELOG.md' do
    real = File.read(File.expand_path('../../CHANGELOG.md', __dir__))
    # A target no release can have pinned, so the drop branch never fires.
    pin = ClaudeAgentSDK::CLIInstaller::PINNED_CLI_VERSION
    result = described_class.update(real, from: pin, to: '99.0.0')
    releases = /^## \[\d.*/m
    unreleased = result[/^## \[Unreleased\]\n.*?(?=^## \[\d)/m]

    expect(unreleased.scan(described_class::ENTRY).length).to eq(1)
    expect(result[releases]).to eq(real[releases])
  end
end
