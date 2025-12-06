# CodeCartographer MCP Server Design

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           AI Client (Claude/Cursor)                      │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                         JSON-RPC 2.0 over stdio
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                              MCPServer                                   │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                        Protocol Handler                          │    │
│  │  • initialize / initialized handshake                            │    │
│  │  • tools/list - expose available tools                           │    │
│  │  • tools/call - route to analyzers                               │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    │                                     │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                     ProjectContext (Cached)                      │    │
│  │  • projectRoot: URL                                              │    │
│  │  • fileCache: [FilePath: CachedFile]                            │    │
│  │  • lastScanTime: Date                                            │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    │                                     │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                         CachedFile                               │    │
│  │  • path: String                                                  │    │
│  │  • contentHash: String (SHA256)                                  │    │
│  │  • ast: SourceFileSyntax (parsed once, reused)                  │    │
│  │  • sourceText: String                                            │    │
│  │  • lastModified: Date                                            │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    │                                     │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                    Existing Analyzers (unchanged)                │    │
│  │  CodeSmellAnalyzer, RefactoringAnalyzer, ImpactAnalyzer, etc.   │    │
│  └─────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
```

## Performance Strategy: Incremental Analysis

### 1. File Hash Cache
```swift
struct CachedFile {
    let path: String
    let contentHash: String        // SHA256 of file contents
    let ast: SourceFileSyntax      // Parsed AST (expensive to create)
    let sourceText: String
    let lastModified: Date
    var analysisCache: [String: Data]  // "smells" -> JSON, "functions" -> JSON
}
```

### 2. Lazy Analysis
- Don't parse all files on `initialize`
- Parse files on-demand when a tool requests them
- Cache the AST after first parse
- Re-parse only if file hash changes

### 3. Analysis Result Caching
- Cache analysis results per file per analyzer
- Invalidate when file hash changes
- Return cached results for unchanged files

### 4. Invalidation Strategy
```swift
// On file change notification or explicit invalidate call:
func invalidateFile(_ path: String) {
    fileCache[path] = nil  // Will re-parse on next access
}

func invalidateAll() {
    fileCache.removeAll()
}
```

## MCP Tools

| Tool | Description | Parameters |
|------|-------------|------------|
| `get_summary` | Quick project health overview | none |
| `analyze_file` | Single file health check | `path: string` |
| `find_smells` | Code smell analysis | `path?: string` (optional, whole project if omitted) |
| `find_god_functions` | Large/complex functions | `minLines?: int, minComplexity?: int` |
| `check_impact` | Blast radius for symbol change | `symbol: string` |
| `suggest_refactoring` | Extraction opportunities | `path?: string` |
| `track_property` | Find property accesses | `pattern: string` |
| `find_calls` | Find method calls | `pattern: string` |
| `list_files` | List Swift files | `path?: string` |
| `read_source` | Read file contents | `path: string, startLine?: int, endLine?: int` |
| `invalidate` | Clear cache for file/all | `path?: string` |

## JSON-RPC Protocol

### Initialize Request
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": { "name": "Claude", "version": "1.0" }
  }
}
```

### Initialize Response
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2024-11-05",
    "capabilities": { "tools": {} },
    "serverInfo": { "name": "CodeCartographer", "version": "1.0.0" }
  }
}
```

### Tools/List Response
```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "tools": [
      {
        "name": "get_summary",
        "description": "Get a quick health summary of the Swift project",
        "inputSchema": {
          "type": "object",
          "properties": {}
        }
      },
      {
        "name": "analyze_file",
        "description": "Get detailed health analysis for a single file",
        "inputSchema": {
          "type": "object",
          "properties": {
            "path": { "type": "string", "description": "Path to the Swift file" }
          },
          "required": ["path"]
        }
      }
    ]
  }
}
```

### Tool Call Response
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"fileCount\": 150, \"codeHealth\": {...}}"
      }
    ]
  }
}
```

## Usage

### Start the server
```bash
codecart serve /path/to/swift/project
```

### Configure in Claude Desktop
```json
{
  "mcpServers": {
    "codecartographer": {
      "command": "/path/to/codecart",
      "args": ["serve", "/path/to/project"]
    }
  }
}
```

### Configure in Cursor/Windsurf
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

## Implementation Files

1. **MCPServer.swift** - JSON-RPC protocol handling, main server loop
2. **MCPTools.swift** - Tool definitions and handlers
3. **ProjectCache.swift** - File caching and incremental updates
4. **main.swift** - Add `serve` subcommand

## Future Enhancements

1. **File watching** - Automatic invalidation on file changes (FSEvents)
2. **Embeddings** - Semantic search over codebase using local embeddings
3. **Resources** - Expose analysis reports as MCP resources
4. **Prompts** - Pre-defined prompts for common refactoring tasks
