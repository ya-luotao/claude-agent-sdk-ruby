# frozen_string_literal: true

require 'ripper'

module ClaudeAgentSDKRailsSpec
  # The ClaudeAgentOptions a Markdown guide builds in its fenced Ruby blocks.
  #
  # Read from the parsed code (Ripper), not from the text, so only what Ruby
  # would run counts: an argument that is commented out is not an argument,
  # and neither is one that only appears inside a string. Where the tree does
  # not settle what a call receives — a `**splat` of a hash the block goes on
  # to use — the option set is reported as not established, never guessed.
  module GuideOptionSets
    # heading: the Markdown heading the block sits under.
    # line: where `ClaudeAgentOptions.new` is called, in the Markdown file.
    # env: the String => String pairs of the `env:` hash the call is built
    #   with, or nil when it has none — or when `problem` says why not.
    # env_line: where that `env:` key is written, in the Markdown file.
    # splats: the local variables the call splats (`**name`), in order.
    # problem: why what the call is built from is not established, or nil.
    OptionSet = Struct.new(:heading, :line, :env, :env_line, :splats, :problem, keyword_init: true)

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
      in_markdown = ->(line) { first_line + line - 1 }
      constructions(program).map do |call, arguments|
        keywords = keyword_pairs(arguments)
        pairs, problem, problem_line = Splat.resolve(keywords, program, call)
        key, value = env_pair(pairs)
        problem += " (line #{in_markdown.call(problem_line)})" if problem_line
        OptionSet.new(heading: heading, line: in_markdown.call(call[3][2][0]),
                      splats: Splat.names(keywords), problem: problem,
                      env: value && string_pairs(value), env_line: key && in_markdown.call(key[2][0]))
      end
    end

    # Every node of the tree — and every list of nodes in it — depth first,
    # parents before children.
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

    # What a `**name` among the keywords of a call stands for.
    #
    # A splat is followed in one shape only, the one that leaves no doubt about
    # what the call receives: `name` is a local variable; `name = { ... }`, a
    # literal that splats nothing itself, is a statement of the sequence the
    # call is in, before it; and the block mentions `name` nowhere else.
    #
    # Another mention may be a write — `name[:env] = {}`, `name.delete(:env)`,
    # `name.merge!(...)`, `name = name.merge(...)`, `name ||= ...`, `helper(name)`
    # — and it need not stand before the call to run before it (a loop, a
    # lambda). The reader does not work out which mentions are harmless: it
    # fails closed on every one of them.
    module Splat
      module_function

      # The pairs a call is built from, every `**name` among its keywords
      # replaced by the pairs of its literal.
      # @return [Array] [pairs], or [[], problem, line of the block] when one
      #   of them cannot be followed
      def resolve(pairs, program, call)
        resolved = []
        pairs.each do |pair|
          next resolved << pair unless pair[0] == :assoc_splat

          literal, problem, line = follow(pair[1], program, call)
          return [[], problem, line] if problem

          resolved.concat(GuideOptionSets.hash_pairs(literal))
        end
        [resolved]
      end

      # The local variables splatted among those keywords.
      def names(pairs)
        pairs.filter_map { |pair| local_name(pair[1]) if pair[0] == :assoc_splat }
      end

      # @return [Array] [the hash literal], or [nil, problem, line of the block]
      def follow(expression, program, call)
        name = local_name(expression)
        return [nil, 'a ** splat that is not a local variable cannot be followed'] unless name

        cannot = "**#{name} cannot be followed: "
        assignment = literal_assignment(program, name)
        return [nil, "#{cannot}the block has no `#{name} = { ... }` literal"] unless assignment

        own = [expression[1], assignment[1][1]] # the splat's identifier and the assignment's
        again = mentions(program, name).find { |mention| own.none? { |identifier| identifier.equal?(mention) } }
        return [nil, "#{cannot}`#{name}` appears again in the block", again[2][0]] if again

        literal = assignment[2]
        splats = GuideOptionSets.hash_pairs(literal).any? { |pair| pair[0] == :assoc_splat }
        return [nil, "#{cannot}its literal splats another hash"] if splats
        return [literal] if runs_before?(program, assignment, call)

        [nil, "#{cannot}`#{name} = { ... }` is not a statement that always runs before the call"]
      end

      # `name` of [:var_ref, [:@ident, name, position]]: an identifier that is
      # a local variable where it stands. One that is not is a :vcall, and a
      # constant is [:var_ref, [:@const, ...]].
      def local_name(expression)
        expression[1][1] if expression.is_a?(Array) && expression[0] == :var_ref && expression[1][0] == :@ident
      end

      # The first [:assign, [:var_field, [:@ident, name, position]], [:hash, ...]].
      def literal_assignment(program, name)
        GuideOptionSets.each_node(program) do |node|
          next unless node[0] == :assign && node[1].is_a?(Array) && node[1][0] == :var_field

          return node if node[1][1][1] == name && node[2].is_a?(Array) && node[2][0] == :hash
        end
        nil
      end

      # Every place the block names `name`, in source order: [:@ident, name,
      # position], and the label of a shorthand pair — `helper(name:)` is
      # [:assoc_new, [:@label, "name:", position], nil].
      def mentions(program, name)
        found = []
        GuideOptionSets.each_node(program) do |node|
          found << node if node[0] == :@ident && node[1] == name
          found << node[1] if node[0] == :assoc_new && node[2].nil? && GuideOptionSets.keyword_name(node[1]) == name
        end
        found.sort_by { |mention| mention[2] }
      end

      # Whether `statement` is one of a sequence of statements in which a later
      # one holds `call`: only then has it run, whatever happened, by the time
      # the call does. (`opts = { ... } if ready` is not: the :if_mod is the
      # statement, and the call may receive `**nil`.) A sequence is an Array of
      # nodes, as in [:program, statements] or [:bodystmt, statements, ...].
      def runs_before?(program, statement, call)
        GuideOptionSets.each_node(program) do |sequence|
          position = sequence[0].is_a?(Array) && sequence.index { |member| member.equal?(statement) }
          next unless position

          return sequence.drop(position + 1).any? { |later| holds?(later, call) }
        end
        false
      end

      def holds?(node, target)
        GuideOptionSets.each_node(node) { |inner| return true if inner.equal?(target) }
        false
      end
    end
  end
end
