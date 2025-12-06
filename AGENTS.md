# CodeCartographer for AI Agents

This guide helps AI coding assistants effectively use CodeCartographer to understand and refactor Swift codebases.

## Quick Reference

```bash
# Get overall codebase health (start here)
codecart /path/to/project --summary

# Get health score for a specific file
codecart /path/to/project --health FileName.swift

# Find refactoring opportunities
codecart /path/to/project --refactor --verbose

# Get extraction details for a specific block
codecart /path/to/project --refactor-detail "FileName.swift:100-200"
```

## Recommended Workflow

### 1. Initial Assessment

Start with `--summary` to get a compact overview:

```bash
codecart /path/to/project --summary
```

Output includes:
- `fileCount` - Project size
- `codeHealth.godFunctions` - Number of functions needing refactoring
- `codeHealth.totalSmells` - Code quality issues
- `refactoring.extractionOpportunities` - Suggested extractions
- `topIssues` - Prioritized list of problems

### 2. Identify Problem Files

If you need to focus on a specific file:

```bash
codecart /path/to/project --health TargetFile.swift
```

Output includes:
- `overallScore` - 0-100 health score (higher is better)
- `smells.byType` - Breakdown of code smells
- `functions.godFunctions` - Large/complex functions in this file
- `refactoring.extractionOpportunities` - Blocks to extract

### 3. Find Refactoring Targets

```bash
codecart /path/to/project --refactor --verbose
```

Look for:
- `godFunctions` - Functions with high line count and complexity
- `extractableBlocks` - Suggested code blocks to extract
- `blockId` - Stable identifier (survives line number changes)
- `generatedSignature` - Ready-to-use function signature

### 4. Get Extraction Details

Once you identify a block to extract:

```bash
codecart /path/to/project --refactor-detail "FileName.swift:START-END"
```

Output includes:
- `fullCode` - The complete code block
- `variablesUsed` - External variables the block depends on
- `functionsCalled` - Functions called within the block
- `generatedFunction` - Ready-to-paste extracted function
- `replacementCall` - Code to replace the original block

### 5. Track Progress

Save a baseline before refactoring:

```bash
codecart /path/to/project --summary --output /tmp/baseline.json
```

After changes, compare:

```bash
codecart /path/to/project --summary --compare /tmp/baseline.json --verbose
```

Shows:
- `delta` - Change in metrics (negative = improvement)
- `improved` - List of metrics that got better
- `regressed` - List of metrics that got worse

## Mode Selection Guide

| Goal | Mode | When to Use |
|------|------|-------------|
| Quick overview | `--summary` | First look at any codebase |
| File-specific issues | `--health FILE` | Deep dive into one file |
| Find extraction targets | `--refactor` | Before refactoring god functions |
| Get extraction code | `--refactor-detail` | When ready to extract a block |
| Track changes | `--summary --compare` | After making changes |
| Understand dependencies | `--types` | Before moving/renaming types |
| Find global state | `--singletons` | Before decoupling |
| Memory issues | `--retain-cycles` | Debugging memory leaks |
| Test coverage | `--tests` | Before adding tests |
| Track property access | `--property "Class.*"` | Find all usages of a class |
| Find method calls | `--calls "*.methodName"` | Find SDK/library calls to migrate |
| Impact of changes | `--impact "Symbol"` | Blast radius before refactoring |

## JSON Output Patterns

All modes output valid JSON to stdout. Use `--verbose` to get human-readable progress on stderr.

### Piping to jq

```bash
# Get just the god functions
codecart /path --refactor 2>/dev/null | jq '.godFunctions[:3]'

# Get health score
codecart /path --health File.swift 2>/dev/null | jq '.overallScore'

# List all smells by type
codecart /path --smells 2>/dev/null | jq '.smellsByType'
```

### Common Fields

Most reports include:
- `analyzedAt` - ISO8601 timestamp
- `fileCount` or `totalFiles` - Number of files analyzed

## Tips for AI Agents

### Do

1. **Start broad, then narrow**: Use `--summary` first, then `--health` for specific files
2. **Use stable identifiers**: The `blockId` field survives line number changes
3. **Trust the generated code**: `generatedFunction` in `--refactor-detail` is ready to use
4. **Track progress**: Save baselines and use `--compare` to verify improvements
5. **Combine modes**: Run `--smells` and `--functions` together to correlate issues

### Don't

1. **Don't parse verbose output**: Always use JSON from stdout, not stderr
2. **Don't assume line numbers are stable**: Use `blockId` for persistent references
3. **Don't extract small blocks**: The tool already filters to blocks > 15 lines
4. **Don't run `--all` for specific tasks**: It's verbose and slow; use targeted modes

## Error Handling

The tool returns exit code 0 on success. Errors go to stderr:

```bash
codecart /nonexistent --summary 2>&1
# ❌ Path does not exist: /nonexistent
```

Common errors:
- `Path does not exist` - Invalid path
- `File not found` - For `--health` or `--refactor-detail` with bad filename
- `No Swift files found` - Empty or non-Swift directory

## Performance

| Project Size | `--summary` Time | `--all` Time |
|--------------|------------------|--------------|
| 30 files | ~0.5s | ~1.5s |
| 300 files | ~2s | ~8s |
| 1000+ files | ~5s | ~20s |

Use targeted modes (`--smells`, `--functions`) for faster results on large projects.

## Example: Refactoring a God Function

```bash
# 1. Find the problem
codecart /path --refactor --verbose 2>&1 | grep "god function"
# main.swift:main - 850 lines, complexity 150

# 2. Get the file health
codecart /path --health main.swift 2>/dev/null | jq '{score: .overallScore, gods: .functions.godFunctions}'
# {"score": 35, "gods": 1}

# 3. Find extractable blocks
codecart /path --refactor 2>/dev/null | jq '.godFunctions[0].extractableBlocks[:3] | .[].blockId'
# "main.swift:main#runTestsAnalysis"
# "main.swift:main#runDepsAnalysis"

# 4. Get extraction details
codecart /path --refactor-detail "main.swift:613-690" 2>/dev/null | jq '.generatedFunction'
# "func runTestsAnalysis(ctx: AnalysisContext, ...) -> Bool { ... }"

# 5. Apply the extraction, then verify
codecart /path --summary --compare /tmp/baseline.json --verbose
# ✅ Improved: God functions: 42 → 41 (-1)
```

## Support

- GitHub: https://github.com/bmdragos/CodeCartographer-Swift
- Issues: Report bugs or request features via GitHub Issues
