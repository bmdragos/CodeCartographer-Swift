# CodeCartographer Feature Roadmap

Ideas for "AI superpowers" - features that maximize Claude's effectiveness when analyzing Swift codebases.

## Status Legend
- 🔴 Not Started
- 🟡 In Progress
- 🟢 Done

---

## 1. Execution Loop 🟡
**Priority: HIGH**

Run code and tests, see actual behavior, not just static analysis.

### Capabilities
- [x] Run `swift test` and parse results
- [x] Build verification (`swift build`)
- [ ] Execute specific test targets
- [ ] Watch mode with incremental feedback
- [ ] Test failure diagnosis with code context
- [ ] Mock input execution for functions

### MCP Tools
```
run_tests(target?, filter?)           # ✅ Implemented
build_and_check()                     # ✅ Implemented
diagnose_test_failure(test_name)
execute_function(signature, mock_inputs)  # Future/sandbox
```

### Value
- Close the feedback loop: analyze → fix → verify
- Catch runtime issues static analysis misses
- Validate fixes immediately

---

## 2. Deep Call Tracing 🔴
**Priority: HIGH**

Full execution path analysis, not just immediate callers/callees.

### Capabilities
- [ ] Forward trace: "What does X call, recursively?"
- [ ] Backward trace: "What calls X, recursively?"
- [ ] Path finding: "Show paths from A to B"
- [ ] Data flow: "Where does this value come from/go to?"

### MCP Tools
```
trace_calls(from: symbol, depth: 5, direction: forward|backward|both)
find_paths(from: symbol, to: symbol, max_paths: 10)
trace_data_flow(variable, file, line)
```

### Value
- Understand complex flows without manual file-hopping
- Find hidden dependencies
- Impact analysis for refactoring

---

## 3. Auto-Fix Suggestions 🔴
**Priority: MEDIUM**

Don't just find issues - propose fixes with diffs.

### Capabilities
- [ ] Force unwrap → guard let/if let transformation
- [ ] Strong delegate → weak delegate fix
- [ ] Missing [weak self] in closures
- [ ] God function → extracted methods
- [ ] Generate the actual code diff

### MCP Tools
```
suggest_fix(smell_id) -> { original, fixed, diff }
apply_fix(smell_id, confirm: true)
batch_fix(smell_type, dry_run: true)
```

### Value
- Reduce manual work translating findings to fixes
- Consistent fix patterns across codebase
- One-click remediation

---

## 4. Diff Analysis 🔴
**Priority: MEDIUM**

Understand changes and their impact over time.

### Capabilities
- [ ] Parse git diff
- [ ] Map changes to analysis (new smells, fixed smells)
- [ ] Blast radius of changes
- [ ] PR review mode: "What should I look at?"

### MCP Tools
```
analyze_diff(base: "HEAD~5", head: "HEAD")
pr_review(branch) -> { new_smells, fixed_smells, risk_areas }
compare_snapshots(before_json, after_json)
```

### Value
- Focus review on what matters
- Track quality over time
- Prevent regressions

---

## 5. Build Error Diagnosis 🔴
**Priority: MEDIUM**

When builds fail, automatically diagnose and suggest fixes.

### Capabilities
- [ ] Parse Swift compiler errors
- [ ] Locate error in AST context
- [ ] Suggest fixes based on error type
- [ ] Common patterns: missing import, type mismatch, etc.

### MCP Tools
```
diagnose_build_error(error_output) -> { file, line, diagnosis, suggested_fix }
fix_build() -> attempts incremental fixes
```

### Value
- Unblock faster when things break
- Learn from common error patterns

---

## 6. Explain Tool 🔴
**Priority: LOW**

Generate high-level explanations of code structure and intent.

### Capabilities
- [ ] Type summary: purpose, relationships, key methods
- [ ] File summary: what this file does, why it exists
- [ ] System summary: how components interact
- [ ] Architecture narrative

### MCP Tools
```
explain(symbol, depth: shallow|deep)
explain_file(path)
explain_system(entry_point)
```

### Value
- Faster onboarding to unfamiliar code
- Documentation generation
- Architecture communication

---

## 7. Pattern Templates / Scaffolding 🔴
**Priority: LOW**

Generate boilerplate following existing codebase patterns.

### Capabilities
- [ ] "Create analyzer like X"
- [ ] "Add MCP tool for Y"
- [ ] Detect and replicate patterns
- [ ] Consistent with existing style

### MCP Tools
```
scaffold(template: "analyzer", name: "ThreadSafetyAnalyzer", like: "CodeSmellAnalyzer")
generate_mcp_tool(name, description, parameters)
```

### Value
- Faster feature development
- Consistency with existing code
- Reduce boilerplate errors

---

## 8. Inline Annotations / Insights 🔴
**Priority: LOW**

Persistent markers and notes attached to code locations.

### Capabilities
- [ ] Mark code with insights that persist
- [ ] "Remember this is tricky because..."
- [ ] Cross-session memory
- [ ] Team-shareable annotations

### Value
- Build up knowledge over time
- Don't re-discover the same things
- Institutional memory

---

## Implementation Notes

### Quick Wins (< 1 day)
- `run_tests` - shell out to `swift test`, parse output
- `diagnose_build_error` - regex parsing of compiler output
- `explain` - combine existing analysis into narrative

### Medium Effort (1-3 days)
- Deep call tracing - extend existing call graph
- Diff analysis - git integration + delta computation
- Auto-fix for simple cases (force unwrap, weak self)

### Larger Effort (1+ week)
- Full auto-fix with AST rewriting
- Execution sandbox for function testing
- Pattern learning for scaffolding

---

## Changelog

### 2025-12-15 (Afternoon)
- Added `build_and_check` MCP tool
- Added `run_tests` MCP tool
- Set up Swift Testing framework (39 tests)
  - 12 tests for CodeSmellAnalyzer
  - 27 tests for ChunkExtractor
- Fixed force cast detection (UnresolvedAsExprSyntax)
- Fixed CallExtractorVisitor whitespace trimming bug

### 2025-12-15
- Initial feature doc created
- Identified 8 capability areas
- Prioritized execution loop as first target
