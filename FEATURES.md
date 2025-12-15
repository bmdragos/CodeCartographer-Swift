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

## 2. Deep Call Tracing 🟢
**Priority: HIGH**

Full execution path analysis, not just immediate callers/callees.

### Capabilities
- [x] Forward trace: "What does X call, recursively?"
- [x] Backward trace: "What calls X, recursively?"
- [x] Path finding: "Show paths from A to B"
- [ ] Data flow: "Where does this value come from/go to?"

### MCP Tools
```
trace_calls(symbol, direction, depth)     # ✅ Implemented
find_call_paths(from, to, max_paths)      # ✅ Implemented
trace_data_flow(variable, file, line)     # Future
```

### Value
- Understand complex flows without manual file-hopping
- Find hidden dependencies
- Impact analysis for refactoring

---

## 3. Auto-Fix Suggestions 🟡
**Priority: MEDIUM**

Don't just find issues - propose fixes with diffs.

### Capabilities
- [x] Force unwrap → guard let/if let transformation
- [x] Force cast → conditional cast (as?)
- [x] Force try → do-catch or try?
- [x] Empty catch → add error logging
- [x] IUO → regular optional
- [ ] Strong delegate → weak delegate fix
- [ ] Missing [weak self] in closures
- [ ] God function → extracted methods
- [ ] Generate unified diff format

### MCP Tools
```
suggest_fix(file, line, smell_type)  # ✅ Implemented
apply_fix(smell_id, confirm: true)   # Future
batch_fix(smell_type, dry_run: true) # Future
```

### Value
- Reduce manual work translating findings to fixes
- Consistent fix patterns across codebase
- One-click remediation

---

## 4. Semantic Search 🟢
**Priority: HIGH**

Natural language code search powered by embeddings.

### Capabilities
- [x] Build vector index from code chunks
- [x] Natural language queries ("authentication logic", "error handling")
- [x] Hybrid search (semantic + regex pattern matching)
- [x] Find similar code chunks
- [x] Incremental index updates on file changes
- [x] Cross-instance cache sharing (multiple editors)

### MCP Tools
```
build_search_index(provider?)           # ✅ Implemented (DGX default)
semantic_search(query, top_k?)          # ✅ Implemented
hybrid_search(query?, pattern?, top_k?) # ✅ Implemented
similar_to(chunk_id, top_k?)            # ✅ Implemented
indexing_status()                       # ✅ Implemented
```

### Value
- Find code by intent, not just keywords
- Discover related code across the codebase
- Combine meaning with patterns for precise results

---

## 6. Diff Analysis 🔴
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

## 7. Build Error Diagnosis 🔴
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

## 8. Explain Tool 🔴
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

## 9. Pattern Templates / Scaffolding 🔴
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

## 10. Inline Annotations / Insights 🔴
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

## Known Issues

### suggest_fix Edge Cases
- Nested expressions like `String(parts.last!)` produce malformed output (captures `String(parts.last` as expression)
- Line numbers can shift between smell detection and fix application - use grep to verify

### main.swift God Function
- 840 lines, cyclomatic complexity 148
- Should be refactored to validate our own tools (eat our own dogfood)

---

## Changelog

### 2025-12-15 (Late Night)
- **Dogfooding v2.2.0** - comprehensive verification of all 41 MCP tools
  - Verified semantic search (402 chunks indexed in 41s with DGX)
  - Verified hybrid search (semantic + regex pattern matching)
  - Verified call tracing (trace_calls, find_call_paths)
  - Verified auto-fix suggestions (5 smell types)
  - Documented known edge cases
- Added Semantic Search to FEATURES.md (was missing!)
- Version bump to 2.2.0

### 2025-12-15 (Night)
- Added Auto-Fix Suggestions (67 tests total)
  - `suggest_fix` MCP tool for generating code fixes
  - AutoFixGenerator with pattern matching for 5 smell types
  - Fixes: force unwrap, force cast, force try, empty catch, IUO
  - Confidence levels: high/medium/low for fix safety
  - 11 tests for AutoFixGenerator

### 2025-12-15 (Evening)
- Added Deep Call Tracing (50 tests total)
  - `trace_calls` MCP tool (forward/backward recursive tracing)
  - `find_call_paths` MCP tool (BFS path finding)
  - CallGraphTracer with symbol resolution and cycle detection
  - 11 tests for CallGraphTracer

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
