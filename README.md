# CodeCartographer

<p align="center">
  <img src="codecartlogo.JPG" alt="CodeCartographer Logo" width="400">
</p>

**Swift Static Analyzer for AI-Assisted Refactoring**

CodeCartographer is a powerful CLI tool that analyzes Swift codebases and outputs structured JSON reports. It's designed to provide rich context for AI coding assistants, enabling more informed refactoring decisions.

## Quick Start

```bash
# Install
git clone https://github.com/bmdragos/CodeCartographer-Swift.git
cd CodeCartographer-Swift
swift build

# See all available modes
.build/debug/codecart --list

# Run an analysis
.build/debug/codecart /path/to/project --smells --verbose
```

> **Note:** Use debug build for now. Release build may crash on Xcode 16.x/Swift 6.x beta due to a compiler optimization bug (CopyPropagation pass). This will be resolved when the toolchain stabilizes.

## Features

CodeCartographer provides **30 analysis modes**:

| Mode | Flag | Description |
|------|------|-------------|
| Singletons | `--singletons` | Global state usage patterns |
| Targets | `--targets-only` | Xcode target membership and orphaned files |
| Auth Migration | `--auth-migration` | Authentication code tracking for migration |
| Types | `--types` | Type definitions, protocols, inheritance |
| Tech Debt | `--tech-debt` | TODO/FIXME/HACK markers |
| Functions | `--functions` | Function metrics (length, complexity) |
| Delegates | `--delegates` | Delegate wiring and potential issues |
| Unused Code | `--unused` | Potentially dead code detection |
| Network | `--network` | API endpoints and network patterns |
| Reactive | `--reactive` | RxSwift/Combine subscriptions and leaks |
| ViewControllers | `--viewcontrollers` | ViewController lifecycle audit |
| Code Smells | `--smells` | Force unwraps, magic numbers, deep nesting |
| Localization | `--localization` | Hardcoded strings and i18n coverage |
| Accessibility | `--accessibility` | Accessibility API coverage audit |
| Threading | `--threading` | Thread safety and concurrency patterns |
| SwiftUI | `--swiftui` | SwiftUI patterns and state management |
| UIKit | `--uikit` | UIKit patterns and modernization score |
| Tests | `--tests` | Test coverage with target awareness |
| Dependencies | `--deps` | CocoaPods/SPM/Carthage analysis |
| Property Access | `--property TARGET` | Track all accesses to a specific pattern |
| Impact Analysis | `--impact SYMBOL` | Analyze blast radius of changing a symbol |
| Migration Checklist | `--checklist` | Generate phased migration plan |
| Core Data | `--coredata` | Core Data model and fetch analysis |
| Documentation | `--docs` | Documentation coverage audit |
| Retain Cycles | `--retain-cycles` | Memory leak risk detection |
| Refactoring | `--refactor` | God function extraction suggestions |
| API Surface | `--api` | Public API surface analysis |
| Summary | `--summary` | Compact AI-friendly overview |
| Health | `--health FILE` | Unified health report for one file |
| Refactor Detail | `--refactor-detail FILE:START-END` | Detailed extraction info for a code block |
| All | `--all` | Run all analyses combined |

## Installation

### From Source

```bash
git clone https://github.com/bmdragos/CodeCartographer-Swift.git
cd CodeCartographer-Swift
swift build -c release
```

The binary will be at `.build/release/codecart`

## Usage

```bash
# List all available analysis modes
codecart --list

# Run code smell analysis with verbose output
codecart /path/to/project --smells --verbose

# Analyze test coverage (auto-detects test targets)
codecart /path/to/project --tests --verbose

# Track property accesses for migration planning
codecart /path/to/project --property "MyClass.shared" --verbose

# Analyze impact of changing a symbol
codecart /path/to/project --impact "AuthManager" --verbose

# Save to file
codecart /path/to/project --functions --output report.json

# Include Xcode target analysis
codecart /path/to/project --project "MyApp.xcodeproj" --targets-only --verbose

# Run all analyses
codecart /path/to/project --all --verbose

# AI-friendly summary
codecart /path/to/project --summary

# Compare with baseline
codecart /path/to/project --summary --output baseline.json
# ... make changes ...
codecart /path/to/project --summary --compare baseline.json

# Get health score for a specific file
codecart /path/to/project --health ViewController.swift

# Get extraction details for refactoring
codecart /path/to/project --refactor-detail "main.swift:100-150"
```

## Example Output

### Singleton Analysis
```
🗺️  CodeCartographer analyzing: /path/to/project
📁 Found 500 Swift files
📊 Running singleton analysis...

📈 Summary:
   Total files analyzed: 500
   Files with references: 320
   Total references: 1500

🔥 Top singletons:
   450x AppState.shared
   220x UserDefaults.standard
   180x NetworkManager.shared
```

### Code Smells
```
🦨 Running code smell analysis...
   Total smells: 1250

🔍 Smells by type:
     Magic Number: 520
     Implicitly Unwrapped Optional: 340
     Force Unwrap (!): 180
     Deep Nesting: 120
     Print Statement in Production: 90
```

### Function Metrics
```
📏 Running function metrics analysis...
   Total functions: 2500
   Average line count: 18.0
   Average complexity: 3.2
   God functions (>50 lines or complexity >10): 45

⚠️ Top god functions:
     parseConfiguration: 120 lines, complexity 25
     processDataBatch: 95 lines, complexity 18
```

## JSON Output

All analyses output structured JSON that can be consumed by AI assistants or other tools:

```json
{
  "analyzedAt": "2025-12-06T14:04:42Z",
  "fileCount": 500,
  "summary": {
    "totalReferences": 1500,
    "singletonUsage": {
      "AppState.shared": 450,
      "UserDefaults.standard": 220
    },
    "hotspotFiles": ["AppState.swift", "MainViewController.swift"]
  }
}
```

## Use Cases

### AI-Assisted Refactoring
Feed CodeCartographer output to AI coding assistants to provide context about:
- Global state dependencies before refactoring
- Which files will be affected by changes
- Technical debt priorities
- Code quality metrics

### Migration Planning
- Track legacy authentication patterns for migration
- Identify all network endpoints before API changes
- Find RxSwift subscriptions before migrating to Combine

### Code Quality Audits
- Find force unwraps and other code smells
- Measure localization coverage
- Audit accessibility support
- Identify god functions needing refactoring

## MCP Server (AI Integration)

CodeCartographer can run as an MCP (Model Context Protocol) server, enabling AI assistants like Claude, Cursor, and Windsurf to directly analyze your Swift codebase.

### Start the Server

```bash
# From your project directory
codecart serve .

# Or specify a path
codecart serve /path/to/swift/project

# With verbose logging (for debugging)
codecart serve /path/to/project --verbose
```

### Configure Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "codecartographer": {
      "command": "/path/to/.build/debug/codecart",
      "args": ["serve", "/path/to/your/project"]
    }
  }
}
```

### Configure Cursor/Windsurf

Add to your MCP settings:

```json
{
  "mcpServers": {
    "codecartographer": {
      "command": "codecart",
      "args": ["serve", "."]
    }
  }
}
```

### Available Tools

| Tool | Description |
|------|-------------|
| `get_summary` | Quick project health overview |
| `analyze_file` | Single file health check |
| `find_smells` | Code smell analysis |
| `find_god_functions` | Large/complex functions |
| `check_impact` | Blast radius for symbol changes |
| `suggest_refactoring` | Extraction opportunities |
| `track_property` | Find property accesses |
| `find_calls` | Find method calls |
| `list_files` | List Swift files |
| `read_source` | Read file contents |
| `invalidate_cache` | Clear cached results |
| `rescan_project` | Rescan for file changes |

### Performance

The MCP server uses intelligent caching:
- Files are hashed and only re-parsed when changed
- Analysis results are cached per-file
- ASTs are parsed lazily on first access

## Requirements

- Swift 5.9+
- macOS 13+ (uses SwiftSyntax 510)

## Contributing

Contributions welcome! Some ideas:
- Additional analyzers (SwiftUI patterns, Core Data usage, etc.)
- Support for other languages (Kotlin, TypeScript)
- IDE integrations
- Visualization tools

## License

MIT License - see [LICENSE](LICENSE)

## Acknowledgments

Built with [SwiftSyntax](https://github.com/apple/swift-syntax) for accurate AST-based analysis.
