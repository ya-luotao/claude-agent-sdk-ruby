# Claude Agent SDK: Ruby vs Python Comparison Review

**Review Date:** 2025-11-04
**Ruby SDK Version:** 0.2.1
**Python SDK Version:** 0.1.6

## Executive Summary

This document provides a comprehensive comparison between the unofficial Ruby SDK and the official Python SDK for Claude Agent. The analysis reveals that while the Ruby SDK has excellent feature parity with most core functionality, **there are 3 critical missing features** introduced in recent Python SDK updates (v0.1.6) that need to be added to the Ruby SDK.

---

## 🔴 CRITICAL MISSING FEATURES

### 1. **`max_budget_usd` Parameter** ⚠️ HIGH PRIORITY

**Status:** ❌ Missing in Ruby SDK
**Python SDK Version:** Added in v0.1.6
**Impact:** High - Cost control is critical for production use

**Description:**
The `max_budget_usd` parameter allows developers to set a maximum spending limit in USD for SDK sessions, preventing unexpected API expenses.

**Python SDK Implementation:**
```python
options = ClaudeAgentOptions(max_budget_usd=0.10)
async for message in query(prompt="...", options=options):
    if isinstance(message, ResultMessage):
        if message.subtype == "error_max_budget_usd":
            print(f"Budget exceeded! Cost: ${message.total_cost_usd}")
```

**CLI Flag:** `--max-budget-usd <value>`

**Required Changes for Ruby SDK:**
1. Add `max_budget_usd` attribute to `ClaudeAgentOptions` class in `lib/claude_agent_sdk/types.rb`
2. Update `build_command` method in `lib/claude_agent_sdk/subprocess_cli_transport.rb` to include `--max-budget-usd` flag
3. Add documentation and example (e.g., `examples/max_budget_usd_example.rb`)

---

### 2. **`max_thinking_tokens` Parameter** ⚠️ MEDIUM PRIORITY

**Status:** ❌ Missing in Ruby SDK
**Python SDK Version:** Added in v0.1.6
**Impact:** Medium - Important for controlling reasoning costs

**Description:**
The `max_thinking_tokens` parameter controls the maximum number of tokens allocated for Claude's internal reasoning process (extended thinking). This is particularly important for Claude Sonnet 4.5 which supports extended thinking.

**Python SDK Implementation:**
```python
options = ClaudeAgentOptions(max_thinking_tokens=2000)
```

**CLI Flag:** `--max-thinking-tokens <value>`

**Required Changes for Ruby SDK:**
1. Add `max_thinking_tokens` attribute to `ClaudeAgentOptions` class
2. Update `build_command` method to include `--max-thinking-tokens` flag
3. Add documentation

---

### 3. **`plugins` Support** ⚠️ MEDIUM PRIORITY

**Status:** ❌ Missing in Ruby SDK
**Python SDK Version:** Available (exact version unclear, but present in v0.1.6)
**Impact:** Medium - Extensibility feature for advanced use cases

**Description:**
The `plugins` parameter allows developers to extend Claude Code with custom commands, agents, skills, and hooks through local plugin directories.

**Python SDK Implementation:**
```python
from pathlib import Path

plugin_path = Path(__file__).parent / "plugins" / "demo-plugin"

options = ClaudeAgentOptions(
    plugins=[{"type": "local", "path": str(plugin_path)}]
)
```

**Plugin Configuration Type:**
```python
class SdkPluginConfig(TypedDict):
    type: Literal["local"]  # Currently only local plugins supported
    path: str
```

**CLI Flag:** `--plugin-dir <path>` (may differ based on actual implementation)

**Required Changes for Ruby SDK:**
1. Add `SdkPluginConfig` class to `lib/claude_agent_sdk/types.rb`
2. Add `plugins` attribute to `ClaudeAgentOptions` class (array of plugin configs)
3. Update `build_command` method to include plugin directory flags
4. Add documentation and example (e.g., `examples/plugin_example.rb`)
5. Consider creating a demo plugin in `examples/plugins/`

---

## ✅ FEATURES WITH FULL PARITY

The following core features are properly implemented in the Ruby SDK:

### Core Functionality
- ✅ `query()` function - Simple one-shot queries
- ✅ `ClaudeSDKClient` / `Client` - Bidirectional interactive conversations
- ✅ Streaming input support via Enumerator
- ✅ Streaming output with message blocks
- ✅ Message types: `UserMessage`, `AssistantMessage`, `SystemMessage`, `ResultMessage`, `StreamEvent`
- ✅ Content blocks: `TextBlock`, `ThinkingBlock`, `ToolUseBlock`, `ToolResultBlock`

### Configuration Options (ClaudeAgentOptions)
- ✅ `allowed_tools` - Whitelist of permitted tools
- ✅ `disallowed_tools` - Blacklist of forbidden tools
- ✅ `system_prompt` - Custom system instructions
- ✅ `model` - Model selection
- ✅ `max_turns` - Limit conversation rounds
- ✅ `permission_mode` - Permission behavior ("default", "acceptEdits", "plan", "bypassPermissions")
- ✅ `permission_prompt_tool_name` - Custom permission prompting tool
- ✅ `continue_conversation` - Resume from previous session
- ✅ `resume` - Resume from specific session ID
- ✅ `fork_session` - Fork from parent session
- ✅ `cwd` - Working directory
- ✅ `cli_path` - Custom Claude Code CLI path
- ✅ `add_dirs` - Additional workspace directories
- ✅ `env` - Environment variables
- ✅ `include_partial_messages` - Include streaming partial updates
- ✅ `agents` - Custom agent definitions
- ✅ `setting_sources` - Configuration source control
- ✅ `stderr` - Stderr callback handler
- ✅ `extra_args` - Additional CLI arguments

### Hooks System
- ✅ Hook support with event types:
  - `PreToolUse`
  - `PostToolUse`
  - `UserPromptSubmit`
  - `Stop`
  - `SubagentStop`
  - `PreCompact`
- ✅ `HookMatcher` - Pattern-based hook targeting
- ✅ Hook callbacks with context

### Permission System
- ✅ `can_use_tool` callback - Dynamic permission decisions
- ✅ `PermissionResultAllow` / `PermissionResultDeny`
- ✅ `PermissionUpdate` - Runtime permission modifications
- ✅ `ToolPermissionContext` - Context for permission decisions

### MCP (Model Context Protocol) Integration
- ✅ SDK MCP servers (in-process tools/resources/prompts)
- ✅ External MCP servers (stdio, SSE, HTTP)
- ✅ Mixed MCP server support (SDK + external)
- ✅ `create_tool()` helper
- ✅ `create_resource()` helper
- ✅ `create_prompt()` helper
- ✅ `create_sdk_mcp_server()` helper
- ✅ JSON schema conversion for tool inputs
- ✅ Tool naming convention: `mcp__<server>__<tool>`

### Agent Definitions
- ✅ `AgentDefinition` class
- ✅ Custom agents with description, prompt, tools, model

### Error Handling
- ✅ `ClaudeSDKError` - Base error
- ✅ `CLINotFoundError` - CLI not installed
- ✅ `CLIConnectionError` - Connection failures
- ✅ `ProcessError` - Process execution errors
- ✅ `CLIJSONDecodeError` - JSON parsing errors
- ✅ `MessageParseError` - Message parsing errors

### Advanced Features
- ✅ Control protocol for bidirectional communication
- ✅ Request/response routing with unique IDs
- ✅ `interrupt()` - Cancel ongoing operations
- ✅ `set_permission_mode()` - Dynamic permission changes
- ✅ `set_model()` - Runtime model switching
- ✅ Version checking (requires Claude Code 2.0.0+)
- ✅ Buffer management with size limits
- ✅ Environment variable setting (`CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_AGENT_SDK_VERSION`)

---

## 📊 EXAMPLES COMPARISON

### Ruby SDK Examples (7 files)
1. ✅ `quick_start.rb` - Basic usage
2. ✅ `client_example.rb` - Interactive client
3. ✅ `streaming_input_example.rb` - Streaming input
4. ✅ `mcp_calculator.rb` - SDK MCP tools
5. ✅ `mcp_resources_prompts_example.rb` - MCP resources/prompts
6. ✅ `hooks_example.rb` - Hook callbacks
7. ✅ `permission_callback_example.rb` - Permission handling

### Python SDK Examples Missing from Ruby (8 files)
1. ❌ `max_budget_usd.py` - Budget control **[NEEDS TO BE ADDED]**
2. ❌ `plugin_example.py` - Plugin usage **[NEEDS TO BE ADDED]**
3. ❌ `agents.py` - Agent definitions (feature exists, but dedicated example missing)
4. ❌ `setting_sources.py` - Setting sources (feature exists, but dedicated example missing)
5. ❌ `stderr_callback_example.py` - Stderr handling (feature exists, but dedicated example missing)
6. ❌ `system_prompt.py` - System prompts (feature exists, but covered in quick_start)
7. ❌ `include_partial_messages.py` - Partial messages (feature exists, not demonstrated)
8. ✅ `streaming_mode_trio.py` - Python-specific (Trio async framework, not applicable to Ruby)

**Recommendation:** Add examples for max_budget_usd, plugins, agents, and setting_sources at minimum.

---

## 🔍 DETAILED COMPARISON: COMMAND LINE FLAGS

### Flags in Both SDKs ✅
```
--output-format stream-json
--verbose
--system-prompt <text>
--append-system-prompt <text>
--allowedTools <list>
--disallowedTools <list>
--max-turns <num>
--model <name>
--permission-prompt-tool <name>
--permission-mode <mode>
--continue
--resume <session_id>
--settings <path>
--add-dir <path>
--mcp-config <json>
--include-partial-messages
--fork-session
--agents <json>
--setting-sources <list>
--input-format stream-json
--print
```

### Missing Flags in Ruby SDK ❌
```
--max-budget-usd <value>          [CRITICAL]
--max-thinking-tokens <value>     [IMPORTANT]
--plugin-dir <path>                [IMPORTANT]
```

---

## 📝 BREAKING CHANGES HISTORY

The Python SDK had a major breaking change at v0.1.0 when renaming from "Claude Code SDK" to "Claude Agent SDK":

### Python SDK v0.1.0 Breaking Changes
1. ✅ `ClaudeCodeOptions` → `ClaudeAgentOptions` (Ruby SDK started with `ClaudeAgentOptions`)
2. ✅ `custom_system_prompt` + `append_system_prompt` → unified `system_prompt` field (Ruby SDK already uses unified `system_prompt`)
3. ✅ Settings/slash commands/subagents no longer loaded by default, require explicit `setting_sources` (Ruby SDK matches this behavior)

**Conclusion:** Ruby SDK already incorporates all breaking changes from Python SDK v0.1.0.

---

## 🧪 TESTING COMPARISON

### Ruby SDK Testing
- **Total Tests:** 86 passing tests
- **Unit Tests:** 66 tests (errors, types, message parsing, MCP server, transport)
- **Integration Tests:** 20 tests
- **Coverage:** Good coverage of core functionality

### Testing Gaps
The following areas may need additional tests when new features are added:
- ❌ Tests for `max_budget_usd` error handling
- ❌ Tests for `max_thinking_tokens` enforcement
- ❌ Tests for plugin loading and execution

---

## 🏗️ ARCHITECTURE COMPARISON

Both SDKs follow nearly identical architectures:

```
User Application
    ↓
query() / Client API
    ↓
Query / InternalClient (Control Protocol Handler)
    ↓
SubprocessCLITransport (Process Management)
    ↓
Claude Code CLI (Node.js)
```

**Key Differences:**
- **Python:** Uses asyncio for async operations
- **Ruby:** Uses async gem (~2.0) for async operations
- **Both:** Implement control protocol for bidirectional communication
- **Both:** Support in-process MCP servers via SDK
- **Both:** Use JSON over stdin/stdout for CLI communication

---

## 🎯 IMPLEMENTATION RECOMMENDATIONS

### Priority 1: HIGH (Implement Immediately)
1. **Add `max_budget_usd` support**
   - Critical for production cost control
   - Required files to modify:
     - `lib/claude_agent_sdk/types.rb` (add attribute)
     - `lib/claude_agent_sdk/subprocess_cli_transport.rb` (add CLI flag)
     - `README.md` (add documentation section)
     - `examples/max_budget_usd_example.rb` (create new example)
     - `spec/unit/types_spec.rb` (add tests)
     - `spec/integration/query_spec.rb` (add integration test)

2. **Add `max_thinking_tokens` support**
   - Important for controlling extended thinking costs
   - Same files to modify as above

### Priority 2: MEDIUM (Implement Soon)
3. **Add `plugins` support**
   - Enhances SDK extensibility
   - Required files:
     - `lib/claude_agent_sdk/types.rb` (add `SdkPluginConfig` class)
     - `lib/claude_agent_sdk/subprocess_cli_transport.rb` (add plugin handling)
     - `examples/plugin_example.rb` (create example)
     - `examples/plugins/demo-plugin/` (create demo plugin)
     - Documentation in README.md

### Priority 3: LOW (Nice to Have)
4. **Add missing examples**
   - `examples/agents_example.rb`
   - `examples/setting_sources_example.rb`
   - `examples/stderr_callback_example.rb`
   - `examples/include_partial_messages_example.rb`

5. **Documentation enhancements**
   - Add migration guide from Python SDK patterns to Ruby SDK
   - Add troubleshooting section
   - Expand API reference

---

## 📋 COMPATIBILITY MATRIX

| Feature | Python SDK v0.1.6 | Ruby SDK v0.2.1 | Status |
|---------|-------------------|-----------------|--------|
| **Core Query API** | ✅ | ✅ | ✅ Full Parity |
| **Client API** | ✅ | ✅ | ✅ Full Parity |
| **Message Types** | ✅ | ✅ | ✅ Full Parity |
| **Content Blocks** | ✅ | ✅ | ✅ Full Parity |
| **Streaming** | ✅ | ✅ | ✅ Full Parity |
| **Tools (allowed/disallowed)** | ✅ | ✅ | ✅ Full Parity |
| **MCP SDK Servers** | ✅ | ✅ | ✅ Full Parity |
| **MCP External Servers** | ✅ | ✅ | ✅ Full Parity |
| **Hooks System** | ✅ | ✅ | ✅ Full Parity |
| **Permission Callbacks** | ✅ | ✅ | ✅ Full Parity |
| **Agent Definitions** | ✅ | ✅ | ✅ Full Parity |
| **Setting Sources** | ✅ | ✅ | ✅ Full Parity |
| **max_budget_usd** | ✅ v0.1.6 | ❌ | ❌ **MISSING** |
| **max_thinking_tokens** | ✅ v0.1.6 | ❌ | ❌ **MISSING** |
| **plugins** | ✅ | ❌ | ❌ **MISSING** |

---

## 🔧 POTENTIAL ISSUES & BUGS

### No Critical Issues Found ✅

After thorough review, the Ruby SDK implementation appears solid with:
- Proper error handling
- Correct message parsing
- Appropriate use of Ruby idioms (blocks, Enumerator)
- Good test coverage
- Clean separation of concerns

### Minor Observations
1. **Ruby SDK version (0.2.1) is higher than Python SDK (0.1.6)**
   This is acceptable as they're independent versioning schemes, but consider documenting the relationship.

2. **Python SDK has more examples**
   While the Ruby SDK has good coverage, adding more examples (especially for newer features) would help adoption.

---

## 📚 DOCUMENTATION COMPARISON

### Python SDK Documentation
- Official Anthropic documentation at docs.claude.com
- Comprehensive README with examples
- CHANGELOG with version history
- 15 example files covering various use cases
- API reference via type hints

### Ruby SDK Documentation
- Community-maintained with clear disclaimer
- Comprehensive README with examples
- 7 example files
- IMPLEMENTATION.md explaining internals
- Good inline code comments

**Gap:** Ruby SDK lacks a CHANGELOG file tracking version history and changes.

**Recommendation:** Add `CHANGELOG.md` to track all version changes for transparency.

---

## ✅ CONCLUSION

### Overall Assessment: **EXCELLENT** 🌟

The Ruby SDK demonstrates exceptional quality and feature parity with the official Python SDK. The implementation is well-architected, properly tested, and follows Ruby best practices.

### Key Strengths
- ✅ 95%+ feature parity with official Python SDK
- ✅ Clean, idiomatic Ruby code
- ✅ Comprehensive test coverage (86 tests)
- ✅ Good documentation
- ✅ All core features working correctly
- ✅ Proper MCP integration
- ✅ Advanced features (hooks, permissions, agents)

### Required Actions
The Ruby SDK is **production-ready** except for 3 missing features from Python SDK v0.1.6:

1. ❌ **`max_budget_usd`** - Critical for cost control
2. ❌ **`max_thinking_tokens`** - Important for extended thinking
3. ❌ **`plugins`** - Useful for extensibility

### Estimated Implementation Effort
- **max_budget_usd:** ~2-3 hours (straightforward parameter addition)
- **max_thinking_tokens:** ~2-3 hours (straightforward parameter addition)
- **plugins:** ~4-6 hours (requires plugin config type, CLI flag handling, example)
- **Total:** ~8-12 hours for complete parity

### Recommendation
**Implement all 3 missing features before promoting to v1.0.0** to ensure full feature parity with the official Python SDK.

---

## 📞 NEXT STEPS

1. **Immediate (This Week)**
   - [ ] Add `max_budget_usd` parameter
   - [ ] Add `max_thinking_tokens` parameter
   - [ ] Add tests for new parameters
   - [ ] Update README with new features

2. **Short-term (Next 2 Weeks)**
   - [ ] Implement `plugins` support
   - [ ] Create plugin example
   - [ ] Add CHANGELOG.md
   - [ ] Add more examples (agents, setting_sources, etc.)

3. **Medium-term (Next Month)**
   - [ ] Monitor Python SDK for new releases
   - [ ] Consider automated compatibility checking
   - [ ] Expand documentation
   - [ ] Consider adding performance benchmarks

---

**Review completed:** 2025-11-04
**Reviewer:** Claude (Sonnet 4.5)
**Status:** ✅ Ruby SDK is nearly feature-complete with 3 minor gaps to address
