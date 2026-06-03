# frozen_string_literal: true

require_relative '../session_store'
require_relative '../session_summary'

module ClaudeAgentSDK
  # Test helpers shipped in the gem for third-party SessionStore adapter authors.
  module Testing # rubocop:disable Metrics/ModuleLength
    # Raised by run_session_store_conformance when a behavioral contract fails.
    class ConformanceError < StandardError; end

    OPTIONAL_METHODS = %w[list_sessions list_session_summaries delete list_subkeys].freeze

    module_function

    # Assert the 14 SessionStore behavioral contracts against an adapter.
    #
    # Framework-agnostic: raises ConformanceError on the first violated
    # contract, otherwise returns nil. Call it from any test framework, e.g.
    #
    #   it 'conforms' do
    #     ClaudeAgentSDK::Testing.run_session_store_conformance(-> { MyStore.new })
    #   end
    #
    # @param make_store [#call] invoked once per contract to provide isolation;
    #   returns a fresh SessionStore (or duck-typed adapter).
    # @param skip_optional [Array<String>] optional method names to skip.
    #   Contracts for an optional method are also skipped automatically when the
    #   store does not override it.
    def run_session_store_conformance(make_store, skip_optional: [])
      skip_optional = skip_optional.map(&:to_s)
      invalid = skip_optional - OPTIONAL_METHODS
      raise ConformanceError, "unknown optional methods in skip_optional: #{invalid}" unless invalid.empty?

      fresh = -> { make_store.call }

      probe = fresh.call
      has_list_sessions = optional?(probe, 'list_sessions', skip_optional)
      has_list_summaries = optional?(probe, 'list_session_summaries', skip_optional)
      has_delete = optional?(probe, 'delete', skip_optional)
      has_list_subkeys = optional?(probe, 'list_subkeys', skip_optional)

      check_append_and_load(fresh, has_list_sessions)
      check_list_sessions(fresh) if has_list_sessions
      check_list_session_summaries(fresh, has_list_sessions, has_delete) if has_list_summaries
      check_delete(fresh, has_list_subkeys, has_list_sessions) if has_delete
      check_list_subkeys(fresh) if has_list_subkeys
      nil
    end

    # -- Required: append + load -------------------------------------------

    def check_append_and_load(fresh, has_list_sessions) # rubocop:disable Metrics/MethodLength
      # 1. append then load returns same entries in same order.
      store = fresh.call
      store.append(key, [entry('uuid' => 'b', 'n' => 1), entry('uuid' => 'a', 'n' => 2)])
      assert_eq(store.load(key), [entry('uuid' => 'b', 'n' => 1), entry('uuid' => 'a', 'n' => 2)],
                'append then load must return the same entries in order')

      # 2. load unknown key returns nil.
      store = fresh.call
      assert(store.load('project_key' => 'proj', 'session_id' => 'nope').nil?,
             'load of an unwritten session must return nil')
      store.append(key, [entry('uuid' => 'x', 'n' => 1)])
      assert(store.load(key.merge('subpath' => 'nope')).nil?,
             'load of an unwritten subpath must return nil')

      # 3. multiple append calls preserve call order.
      store = fresh.call
      store.append(key, [entry('uuid' => 'z', 'n' => 1)])
      store.append(key, [entry('uuid' => 'a', 'n' => 2), entry('uuid' => 'm', 'n' => 3)])
      store.append(key, [entry('uuid' => 'b', 'n' => 4)])
      assert_eq(store.load(key),
                [entry('uuid' => 'z', 'n' => 1), entry('uuid' => 'a', 'n' => 2),
                 entry('uuid' => 'm', 'n' => 3), entry('uuid' => 'b', 'n' => 4)],
                'multiple appends must preserve call order')

      # 4. append([]) is a no-op.
      store = fresh.call
      store.append(key, [entry('uuid' => 'a', 'n' => 1)])
      store.append(key, [])
      assert_eq(store.load(key), [entry('uuid' => 'a', 'n' => 1)], 'append([]) must be a no-op')

      # 5. subpath keys are stored independently of main.
      store = fresh.call
      sub = key.merge('subpath' => 'subagents/agent-1')
      store.append(key, [entry('uuid' => 'm', 'n' => 1)])
      store.append(sub, [entry('uuid' => 's', 'n' => 1)])
      assert_eq(store.load(key), [entry('uuid' => 'm', 'n' => 1)], 'main transcript must be independent of subpath')
      assert_eq(store.load(sub), [entry('uuid' => 's', 'n' => 1)], 'subpath transcript must be independent of main')

      # 6. project_key isolation.
      store = fresh.call
      store.append({ 'project_key' => 'A', 'session_id' => 's1' }, [entry('from' => 'A')])
      store.append({ 'project_key' => 'B', 'session_id' => 's1' }, [entry('from' => 'B')])
      assert_eq(store.load('project_key' => 'A', 'session_id' => 's1'), [entry('from' => 'A')],
                'project_key A must be isolated')
      assert_eq(store.load('project_key' => 'B', 'session_id' => 's1'), [entry('from' => 'B')],
                'project_key B must be isolated')
      return unless has_list_sessions

      assert_eq(store.list_sessions('A').length, 1, 'project A must list one session')
      assert_eq(store.list_sessions('B').length, 1, 'project B must list one session')
    end

    # -- Optional: list_sessions -------------------------------------------

    def check_list_sessions(fresh)
      # 7. list_sessions returns session_ids for project.
      store = fresh.call
      store.append({ 'project_key' => 'proj', 'session_id' => 'a' }, [entry('n' => 1)])
      store.append({ 'project_key' => 'proj', 'session_id' => 'b' }, [entry('n' => 1)])
      store.append({ 'project_key' => 'other', 'session_id' => 'c' }, [entry('n' => 1)])
      sessions = store.list_sessions('proj')
      assert_eq(sessions.map { |s| s['session_id'] }.sort, %w[a b], 'list_sessions must scope to the project')
      assert(sessions.all? { |s| epoch_ms?(s['mtime']) }, 'list_sessions mtime must be epoch-ms (> 1e12)')
      assert_eq(store.list_sessions('never-appended-project'), [], 'unknown project must list no sessions')

      # 8. list_sessions excludes subagent subpaths.
      store = fresh.call
      store.append({ 'project_key' => 'proj', 'session_id' => 'main' }, [entry('n' => 1)])
      store.append({ 'project_key' => 'proj', 'session_id' => 'main', 'subpath' => 'subagents/agent-1' },
                   [entry('n' => 1)])
      assert_eq(store.list_sessions('proj').map { |s| s['session_id'] }, ['main'],
                'list_sessions must exclude subagent subpaths')
    end

    # -- Optional: list_session_summaries ----------------------------------

    def check_list_session_summaries(fresh, has_list_sessions, has_delete)
      # 14. persisted fold output round-trips through fold_session_summary.
      store = fresh.call
      summ_key = { 'project_key' => 'proj', 'session_id' => 'summ-sess' }
      store.append(summ_key, [entry('timestamp' => '2024-01-01T00:00:00.000Z', 'customTitle' => 'first'),
                              entry('timestamp' => '2024-01-01T00:00:01.000Z')])
      store.append(summ_key, [entry('timestamp' => '2024-01-01T00:00:02.000Z', 'customTitle' => 'second')])
      store.append({ 'project_key' => 'other', 'session_id' => 'elsewhere' },
                   [entry('timestamp' => '2024-01-01T00:00:00.000Z')])

      by_id = store.list_session_summaries('proj').to_h { |s| [s['session_id'], s] }
      assert_eq(by_id.keys, ['summ-sess'], 'list_session_summaries must scope to the project')
      summ = by_id['summ-sess']
      assert(epoch_ms?(summ['mtime']), 'summary mtime must be epoch-ms (> 1e12)')

      if has_list_sessions
        ls_by_id = store.list_sessions('proj').to_h { |e| [e['session_id'], e['mtime']] }
        assert(summ['mtime'] >= ls_by_id['summ-sess'],
               'summary mtime must share a clock with (and be >=) list_sessions mtime')
      end

      assert(summ['data'].is_a?(Hash), 'summary data must be a Hash')
      refolded = SessionSummary.fold_session_summary(summ, summ_key, [entry('timestamp' => '2024-01-01T00:00:03.000Z')])
      assert_eq(refolded['session_id'], 'summ-sess', 'refold must preserve session_id')
      assert_eq(refolded['mtime'], summ['mtime'], 'fold must preserve prev mtime verbatim')

      # Subagent appends must NOT affect the main session's summary.
      store.append(summ_key.merge('subpath' => 'subagents/agent-1'),
                   [entry('timestamp' => '2024-01-01T00:00:09.000Z', 'customTitle' => 'subagent')])
      after_sub = store.list_session_summaries('proj').to_h { |s| [s['session_id'], s] }
      assert_eq(after_sub['summ-sess']['data'], summ['data'], 'subagent appends must not change the main summary')
      assert_eq(store.list_session_summaries('never-appended-project'), [], 'unknown project must list no summaries')

      return unless has_delete

      store.delete(summ_key)
      assert_eq(store.list_session_summaries('proj'), [], 'delete must clear the session summary')
    end

    # -- Optional: delete --------------------------------------------------

    def check_delete(fresh, has_list_subkeys, has_list_sessions)
      # 9. delete main then load returns nil (delete of never-written is a no-op).
      store = fresh.call
      store.delete('project_key' => 'proj', 'session_id' => 'never-written')
      store.append(key, [entry('n' => 1)])
      store.delete(key)
      assert(store.load(key).nil?, 'load after delete must return nil')

      # 10. delete main cascades to subkeys; siblings/other projects survive.
      store = fresh.call
      sub1 = key.merge('subpath' => 'subagents/agent-1')
      sub2 = key.merge('subpath' => 'subagents/agent-2')
      other = { 'project_key' => 'proj', 'session_id' => 'sess2' }
      other_proj = { 'project_key' => 'other-proj', 'session_id' => key['session_id'] }
      [key, sub1, sub2, other, other_proj].each { |k| store.append(k, [entry('n' => 1)]) }

      store.delete(key)

      assert(store.load(key).nil?, 'delete must remove the main transcript')
      assert(store.load(sub1).nil?, 'delete must cascade to subkey 1')
      assert(store.load(sub2).nil?, 'delete must cascade to subkey 2')
      assert((store.load(other) || []).length == 1, 'sibling session must survive delete')
      assert((store.load(other_proj) || []).length == 1, 'other project must survive delete')
      assert_eq(store.list_subkeys(key), [], 'list_subkeys must be empty after cascade delete') if has_list_subkeys
      if has_list_sessions
        listed = store.list_sessions(key['project_key']).map { |s| s['session_id'] }
        assert(!listed.include?(key['session_id']), 'deleted session must not be listed')
      end

      # 11. delete with subpath removes only that subkey.
      store = fresh.call
      [key, sub1, sub2].each { |k| store.append(k, [entry('n' => 1)]) }
      store.delete(sub1)
      assert(store.load(sub1).nil?, 'targeted subpath delete must remove that subkey')
      assert((store.load(sub2) || []).length == 1, 'targeted subpath delete must spare other subkeys')
      assert((store.load(key) || []).length == 1, 'targeted subpath delete must spare the main transcript')
      return unless has_list_subkeys

      assert_eq(store.list_subkeys(key), ['subagents/agent-2'], 'only the deleted subkey must be gone')
    end

    # -- Optional: list_subkeys --------------------------------------------

    def check_list_subkeys(fresh)
      # 12. list_subkeys returns subpaths (scoped to the session).
      store = fresh.call
      store.append(key, [entry('n' => 1)])
      store.append(key.merge('subpath' => 'subagents/agent-1'), [entry('n' => 1)])
      store.append(key.merge('subpath' => 'subagents/agent-2'), [entry('n' => 1)])
      store.append({ 'project_key' => key['project_key'], 'session_id' => 'other-sess',
                     'subpath' => 'subagents/agent-x' }, [entry('n' => 1)])
      subkeys = store.list_subkeys(key)
      assert_eq(subkeys.sort, ['subagents/agent-1', 'subagents/agent-2'], "list_subkeys must return this session's subpaths")
      assert(!subkeys.include?('subagents/agent-x'), "list_subkeys must not leak another session's subkeys")

      # 13. list_subkeys excludes the main transcript.
      store = fresh.call
      store.append(key, [entry('n' => 1)])
      assert_eq(store.list_subkeys(key), [], 'list_subkeys must exclude the main transcript')
      assert_eq(store.list_subkeys('project_key' => 'proj', 'session_id' => 'never-appended'), [],
                'list_subkeys of an unknown session must be empty')
    end

    # -- helpers -----------------------------------------------------------

    def key
      { 'project_key' => 'proj', 'session_id' => 'sess' }
    end

    # Build a test entry satisfying SessionStoreEntry (type is required). The
    # value of type is irrelevant to the contracts — entries are opaque blobs.
    def entry(extra = {})
      { 'type' => 'x' }.merge(extra)
    end

    def epoch_ms?(value)
      value.is_a?(Numeric) && value.finite? && value > 1e12
    end

    def optional?(store, method, skip_optional)
      return false if skip_optional.include?(method)

      SessionStore.implements?(store, method.to_sym)
    end

    def assert(condition, message)
      raise ConformanceError, "SessionStore conformance failed: #{message}" unless condition
    end

    def assert_eq(actual, expected, message)
      return if actual == expected

      raise ConformanceError,
            "SessionStore conformance failed: #{message}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
    end

    private_class_method :check_append_and_load, :check_list_sessions, :check_list_session_summaries,
                         :check_delete, :check_list_subkeys, :key, :entry, :epoch_ms?, :optional?,
                         :assert, :assert_eq
  end
end
