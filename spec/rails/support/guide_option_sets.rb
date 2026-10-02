# frozen_string_literal: true

require 'ripper'

module ClaudeAgentSDKRailsSpec
  # The ClaudeAgentOptions a Markdown guide builds in its fenced Ruby blocks.
  #
  # Read from the parsed code (Ripper), not from the text, so only what Ruby
  # would run counts: an argument that is commented out is not an argument,
  # and neither is one that only appears inside a string.
  module GuideOptionSets
    # heading: the Markdown heading the block sits under.
    # line: where `ClaudeAgentOptions.new` is called, in the Markdown file.
    # env: the String => String pairs of the `env:` hash the call is built
    #   with, or nil when it has none.
    # env_line: where that `env:` key is written, in the Markdown file.
    OptionSet = Struct.new(:heading, :line, :env, :env_line, keyword_init: true)

    FENCED_RUBY = /^(\#{2,3} [^\n]+)$|^ *```ruby\n(.*?)^ *```$/m

    module_function

    # @param markdown [String]
    # @return [Array<OptionSet>] in document order
    def in_markdown(markdown)
      heading = nil
      sets = []
      markdown.scan(FENCED_RUBY) do |title, code|
        next heading = title.sub(/\A#+ /, '') if title

        first_line = Regexp.last_match.pre_match.count("\n") + 2 # the line after the opening fence
        program = Ripper.sexp(code) || raise(ArgumentError, "the Ruby block under \"#{heading}\" does not parse")
        sets.concat(option_sets(program, heading, first_line))
      end
      sets
    end

    def option_sets(program, heading, first_line)
      constructions(program).map do |call, arguments|
        key, value = env_pair(resolved_pairs(keyword_pairs(arguments), program))
        OptionSet.new(heading: heading, line: first_line + call[3][2][0] - 1,
                      env: value && string_pairs(value), env_line: key && (first_line + key[2][0] - 1))
      end
    end

    # Every node of the tree, depth first, parents before children.
    def each_node(node, &block)
      return unless node.is_a?(Array)

      yield node
      node.each { |child| each_node(child, &block) }
    end

    # Every `ClaudeAgentOptions.new`, as [the call, its arguments or nil]:
    #   new(...)    [:method_add_arg, [:call, receiver, _, [:@ident, "new", _]], arg_paren]
    #   new ...     [:command_call, receiver, _, [:@ident, "new", _], arguments]
    #   new         [:call, receiver, _, [:@ident, "new", _]]
    def constructions(program)
      found = []
      with_parentheses = []
      each_node(program) do |node|
        case node[0]
        when :method_add_arg
          next unless construction?(node[1])

          with_parentheses << node[1]
          found << [node[1], node[2]]
        when :command_call then found << [node, node[4]] if construction?(node)
        when :call then found << [node, nil] if construction?(node) && with_parentheses.none? { |call| call.equal?(node) }
        end
      end
      found
    end

    def construction?(call)
      call.is_a?(Array) && %i[call command_call].include?(call[0]) && call[3].is_a?(Array) &&
        call[3][1] == 'new' && constant_name(call[1]) == 'ClaudeAgentOptions'
    end

    # The last constant of `A::B` or of a bare `B`.
    def constant_name(node)
      return unless node.is_a?(Array)

      case node[0]
      when :const_path_ref then node[2][1]
      when :var_ref then node[1][1] if node[1][0] == :@const
      end
    end

    # The call's own keyword arguments — [:assoc_new, key, value] and
    # [:assoc_splat, expression] nodes — without descending into the values.
    def keyword_pairs(arguments)
      queue = [arguments]
      until queue.empty?
        node = queue.shift
        next unless node.is_a?(Array)
        return node[1] if node[0] == :bare_assoc_hash

        queue.concat(node) if node[0].is_a?(Array) || %i[arg_paren args_add_block].include?(node[0])
      end
      []
    end

    # A `**name` among the keywords stands for the pairs of the `name = { ... }`
    # literal assigned in the same block.
    def resolved_pairs(pairs, program)
      pairs.flat_map do |pair|
        next [pair] unless pair[0] == :assoc_splat

        hash_pairs(assigned_hash(program, pair.dig(1, 1, 1)))
      end
    end

    def assigned_hash(program, name)
      each_node(program) do |node|
        next unless node[0] == :assign && node[1].is_a?(Array) && node[1][0] == :var_field

        return node[2] if node[1][1][1] == name && node[2].is_a?(Array) && node[2][0] == :hash
      end
      nil
    end

    # [:hash, [:assoclist_from_args, pairs]], or [:hash, nil] for {}.
    def hash_pairs(hash)
      return [] unless hash.is_a?(Array) && hash[0] == :hash && hash[1]

      hash[1][1]
    end

    # The key and the hash literal of the `env:` keyword, if there is one. Of
    # two `env:` the last counts, as in Ruby; one that is not a hash literal
    # cannot be read, and counts as none.
    def env_pair(pairs)
      pair = pairs.reverse_each.find { |node| node[0] == :assoc_new && keyword_name(node[1]) == 'env' }
      pair && pair[2].is_a?(Array) && pair[2][0] == :hash ? [pair[1], pair[2]] : [nil, nil]
    end

    # `env:` is [:@label, "env:", position].
    def keyword_name(key)
      key[1].delete_suffix(':') if key[0] == :@label
    end

    # The pairs of a hash literal whose key and value are both plain strings.
    def string_pairs(hash)
      hash_pairs(hash).filter_map do |pair|
        key = string_value(pair[1])
        value = string_value(pair[2])
        [key, value] if pair[0] == :assoc_new && key && value
      end.to_h
    end

    # 'text' is [:string_literal, [:string_content, [:@tstring_content, "text", position]]].
    def string_value(node)
      return unless node.is_a?(Array) && node[0] == :string_literal

      parts = node[1][1..]
      parts.map { |part| part[1] }.join if parts.all? { |part| part[0] == :@tstring_content }
    end
  end
end
