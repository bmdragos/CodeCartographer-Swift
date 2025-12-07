# CodeCartographer for AI Agents

CodeCartographer is an MCP server providing 37 tools for Swift codebase analysis. This guide helps AI coding assistants use it effectively.

## Quick Reference

### Starting a Session

```
1. set_project("/path/to/swift/project")  → Switch to project
2. get_summary                             → Project health overview
3. Use specific tools based on task
```

### Most Used Tools

| Tool | When to Use |
|------|-------------|
| `set_project` | Switch to a different codebase |
| `get_summary` | First look at any project |
| `analyze_file` | Deep-dive into a specific file |
| `find_smells` | Find code quality issues |
| `find_god_functions` | Find functions needing refactoring |
| `check_impact` | Before modifying a symbol |
| `suggest_refactoring` | Get extraction suggestions |
| `read_source` | Read actual code |

## All 37 Tools

### Project Management
| Tool | Description |
|------|-------------|
| `get_version` | Version info and current project status |
| `set_project` | Switch to a different Swift project |
| `get_summary` | Project health overview |
| `get_architecture_diagram` | Mermaid.js architecture diagram |
| `analyze_file` | Single file health check |
| `list_files` | List Swift files |
| `read_source` | Read file contents |
| `invalidate_cache` | Clear cached results |
| `rescan_project` | Detect new/deleted files |

### Code Quality
| Tool | Description |
|------|-------------|
| `find_smells` | Force unwraps, magic numbers, nesting |
| `find_god_functions` | Large/complex functions |
| `find_retain_cycles` | Memory leak risks |
| `find_unused_code` | Dead code |
| `find_tech_debt` | TODO/FIXME/HACK |
| `find_threading_issues` | Thread safety |

### Refactoring
| Tool | Description |
|------|-------------|
| `suggest_refactoring` | Extraction opportunities |
| `get_refactor_detail` | Ready-to-paste extracted function |
| `check_impact` | Blast radius for symbol changes |
| `track_property` | Find property accesses |
| `find_calls` | Find method call patterns |

### Architecture
| Tool | Description |
|------|-------------|
| `find_types` | Types, protocols, inheritance |
| `find_delegates` | Delegate wiring |
| `find_singletons` | Global state (.shared, .default) |
| `analyze_api_surface` | Public API signatures |

### Framework-Specific
| Tool | Description |
|------|-------------|
| `analyze_swiftui` | @State, @Binding patterns |
| `analyze_uikit` | UIKit modernization score |
| `find_viewcontrollers` | VC lifecycle audit |
| `analyze_coredata` | Core Data usage |
| `find_reactive` | RxSwift/Combine subscriptions |
| `find_network_calls` | API endpoints |

### Migration & Quality
| Tool | Description |
|------|-------------|
| `analyze_auth_migration` | Auth code tracking |
| `generate_migration_checklist` | Phased migration plan |
| `analyze_dependencies` | CocoaPods/SPM/Carthage |
| `find_localization_issues` | i18n coverage |
| `find_accessibility_issues` | Accessibility audit |
| `analyze_docs` | Documentation coverage |
| `analyze_tests` | Test coverage |

## Common Workflows

### Understanding a New Codebase

```
1. set_project("/path/to/project")
2. get_summary
   → fileCount, godFunctions, totalSmells, topIssues
3. find_types
   → Type hierarchy and protocols
4. find_singletons
   → Global state patterns
```

### Refactoring a God Function

```
1. get_summary
   → Identify god functions
2. analyze_file("TargetFile.swift")
   → Get file health score
3. suggest_refactoring("TargetFile.swift")
   → Get extraction opportunities
4. check_impact("FunctionName")
   → See what's affected
5. get_refactor_detail("TargetFile.swift", 100, 200)
   → Get ready-to-paste extracted function
```

### Migration Planning

```
1. track_property("LegacyManager.*")
   → Find all usages
2. find_calls("*.deprecatedMethod")
   → Find method calls to migrate
3. check_impact("LegacyManager")
   → Blast radius
4. generate_migration_checklist
   → Phased plan
```

### Code Review

```
1. analyze_file("ChangedFile.swift")
   → Health score
2. find_smells("ChangedFile.swift")
   → Quality issues
3. find_retain_cycles("ChangedFile.swift")
   → Memory leaks
4. find_threading_issues("ChangedFile.swift")
   → Concurrency problems
```

## Response Format

All tools return compact JSON. Key fields:

```json
{
  "fileCount": 33,
  "godFunctions": 5,
  "totalSmells": 171,
  "topIssues": ["5 god functions need refactoring"],
  "smellsByType": {"Force Unwrap": 10, "Magic Number": 50}
}
```

## Performance Notes

- **First query** may take 1-5s (parsing)
- **Subsequent queries** are instant (cached)
- **File changes** auto-invalidate cache
- **set_project** clears cache and switches

## Tips

### Do
- Start with `get_summary` for any new project
- Use `check_impact` before major changes
- Trust `get_refactor_detail` output - it's ready to use
- Use path filters to narrow scope: `find_smells("ViewController.swift")`

### Don't
- Call every tool - use targeted analysis
- Ignore cached results - they're still valid
- Skip `check_impact` - blast radius matters

## Error Handling

Tools return errors in JSON:

```json
{"error": "File not found: NonExistent.swift"}
```

Common errors:
- `File not found` - Bad path
- `No Swift files` - Empty/non-Swift directory
- `Ambiguous path` - Multiple files match

## CLI Fallback

If MCP isn't available, use CLI:

```bash
codecart /path/to/project --summary
codecart /path/to/project --smells --verbose
codecart /path/to/project --refactor-detail "File.swift:100-200"
```
