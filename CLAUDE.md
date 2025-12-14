# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Version:** 2.0.4

## Build Commands

```bash
# Build
swift build

# Build release
swift build -c release

# Run directly
swift run codecart <path> --summary

# Run MCP server
swift run codecart serve [path] [--verbose]

# Install globally (symlink to release build)
sudo ln -sf "$(pwd)/.build/release/codecart" /usr/local/bin/codecart
```

## Architecture Overview

CodeCartographer is an MCP server providing 40+ static analysis tools for Swift codebases. It enables AI assistants to deeply understand Swift projects through AST analysis, semantic search, and code quality metrics.

### Core Components

**MCPServer.swift** - JSON-RPC 2.0 server implementing the Model Context Protocol. Handles tool dispatch for all 40 analysis tools. Supports dynamic project switching via `set_project`.

**ASTCache.swift** - Central caching system with three layers:
- `ParsedFile` - Lazy AST parsing per file with content hash tracking
- `resultCache` - Tool output caching (invalidated on any file change)
- `findingsCache` / `chunksCache` - Per-file analysis caching keyed by content hash
- Includes FSEvents-based file watching for automatic cache invalidation

**ChunkExtractor.swift** - AST-aware code chunking for semantic search. Extracts:
- Type definitions (class, struct, enum, protocol)
- Functions/methods with call graph relationships
- Special chunks: hotspots (quality issues), file summaries, protocol clusters, type summaries

**EmbeddingProvider.swift** - Pluggable embedding system:
- `NLEmbeddingProvider` - Local Apple NLEmbedding (512 dims, no setup)
- `DGXEmbeddingProvider` - Remote GPU server for NV-Embed-v2 (4096 dims)

**EmbeddingIndex.swift** - In-memory vector index with cosine similarity search. Features:
- Thread-safe with pthread_rwlock_t (reader-writer lock)
- Incremental updates when files change
- Cross-process file locking (flock) for multi-instance safety
- Schema versioning (v6) - cache auto-invalidates on schema changes
- Job ID tracking for DGX job resume

### Analyzer Pattern

Each analyzer (e.g., `CodeSmellAnalyzer.swift`, `RetainCycleAnalyzer.swift`) follows the same pattern:
1. Takes `[ParsedFile]` as input
2. Uses SwiftSyntax visitors to walk ASTs
3. Returns structured Codable results
4. Results are cached by ASTCache

### Data Flow

```
Swift Files → ASTCache (lazy parse) → Analyzers → JSON Results
                  ↓
            ChunkExtractor → EmbeddingProvider → EmbeddingIndex → Semantic Search
```

### Key Types

- `ParsedFile` - File with lazy AST and content hash
- `CodeChunk` - Embeddable code unit with rich metadata (calls, calledBy, layer, patterns)
- `FileFindings` - Per-file analysis results (smells, complexity, singletons, etc.)
- `JSONValue` - Dynamic JSON for MCP protocol handling

## CLI Modes

Run `codecart --list` to see all 30+ analysis modes. Common ones:
- `--summary` - AI-friendly health overview
- `--smells` - Code smell detection
- `--functions` - God function detection
- `--refactor` - Extraction suggestions
- `--impact SYMBOL` - Blast radius analysis

## MCP Server Mode

`codecart serve [path]` starts the JSON-RPC server over stdio. Project can be set dynamically via `set_project` tool if no path provided at startup.

## Embedding Cache & Cross-Instance Sync (v2.0)

Cache location: `~/.codecartographer/cache/<project-hash>.json`

### Indexing Behavior
- **Default provider:** DGX (NV-Embed-v2, 4096 dims)
- **Batch size:** Dynamic from server `/capabilities` (typically 48-64 for DGX)
- **Checkpoints:** Saved every 500 chunks for crash recovery
- **Auto-start:** Indexing begins automatically on server startup
- **Job queue:** DGX server manages multi-instance job coordination

### Cross-Instance Sync
Multiple codecart instances (e.g., Claude Code + Windsurf) pointing at the same repo share embeddings:
- **File locking:** `flock()` prevents cache corruption during concurrent writes
- **Cache watching:** DispatchSource monitors cache file for external changes
- **Auto-reload:** When another instance saves, changes are detected and loaded
- **Indexing protection:** Reloads are skipped while actively indexing

### Content Hashing
Files are tracked via SHA256 content hash (not Swift's randomized `hashValue`). Changed files trigger incremental re-embedding of affected chunks only.

### Monitoring Tools (v2.0)
Non-blocking tools for checking indexing and DGX server status:
- `indexing_status` - Check embedding progress (status, progress%, ETA, chunks/sec)
- `dgx_health` - DGX server health (GPU memory, model info, max batch size)
- `dgx_stats` - DGX runtime stats (requests, throughput, queue depth, errors)
- `dgx_jobs` - List active/queued/recent jobs across all instances

### Future Improvements
- **Client-side skip:** Filter already-embedded chunks before sending to DGX, avoiding re-computation after server restart
