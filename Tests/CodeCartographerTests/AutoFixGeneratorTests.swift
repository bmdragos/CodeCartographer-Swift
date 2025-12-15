import Testing
import Foundation
@testable import CodeCartographer

@Suite("AutoFixGenerator Tests")
struct AutoFixGeneratorTests {

    // MARK: - Force Unwrap Fixes

    @Test("Generates guard let for force unwrap assignment")
    func generatesGuardLetForForceUnwrap() {
        let (generator, tempDir) = makeGenerator(with: "let value = optional!")

        let smell = makeSmell(type: .forceUnwrap, line: 1, file: "test.swift")
        let result = generator.suggestFix(for: smell)

        #expect(result.canAutoFix == true)
        #expect(result.suggestion?.fixed.contains("guard let") == true)
        #expect(result.suggestion?.confidence == .medium)

        cleanup(tempDir)
    }

    @Test("Preserves indentation in force unwrap fix")
    func preservesIndentationForceUnwrap() {
        let (generator, tempDir) = makeGenerator(with: "        let value = optional!")

        let smell = makeSmell(type: .forceUnwrap, line: 1, file: "test.swift")
        let result = generator.suggestFix(for: smell)

        #expect(result.suggestion?.fixed.hasPrefix("        ") == true)

        cleanup(tempDir)
    }

    // MARK: - Force Cast Fixes

    @Test("Generates guard let for force cast")
    func generatesGuardLetForForceCast() {
        let (generator, tempDir) = makeGenerator(with: "let view = anyObject as! UIView")

        let smell = makeSmell(type: .forceCast, line: 1, file: "test.swift")
        let result = generator.suggestFix(for: smell)

        #expect(result.canAutoFix == true)
        #expect(result.suggestion?.fixed.contains("as?") == true)

        cleanup(tempDir)
    }

    @Test("Simple force cast replacement")
    func simpleForceCastReplacement() {
        let (generator, tempDir) = makeGenerator(with: "process(item as! String)")

        let smell = makeSmell(type: .forceCast, line: 1, file: "test.swift")
        let result = generator.suggestFix(for: smell)

        #expect(result.canAutoFix == true)
        #expect(result.suggestion?.fixed.contains("as?") == true)
        #expect(result.suggestion?.fixed.contains("as!") == false)

        cleanup(tempDir)
    }

    // MARK: - Force Try Fixes

    @Test("Generates do-catch for force try assignment")
    func generatesDoTryCatch() {
        let (generator, tempDir) = makeGenerator(with: "let data = try! loadData()")

        let smell = makeSmell(type: .forceTry, line: 1, file: "test.swift")
        let result = generator.suggestFix(for: smell)

        #expect(result.canAutoFix == true)
        #expect(result.suggestion?.fixed.contains("do {") == true || result.suggestion?.fixed.contains("try?") == true)

        cleanup(tempDir)
    }

    @Test("Simple force try to optional try")
    func simpleForceTryToOptional() {
        let (generator, tempDir) = makeGenerator(with: "process(try! risky())")

        let smell = makeSmell(type: .forceTry, line: 1, file: "test.swift")
        let result = generator.suggestFix(for: smell)

        #expect(result.canAutoFix == true)
        #expect(result.suggestion?.fixed.contains("try?") == true)

        cleanup(tempDir)
    }

    // MARK: - Empty Catch Fixes

    @Test("Generates logging for empty catch")
    func generatesLoggingForEmptyCatch() {
        let (generator, tempDir) = makeGenerator(with: "} catch {")

        let smell = makeSmell(type: .emptycatch, line: 1, file: "test.swift")
        let result = generator.suggestFix(for: smell)

        #expect(result.canAutoFix == true)
        #expect(result.suggestion?.fixed.contains("error") == true)

        cleanup(tempDir)
    }

    // MARK: - Implicitly Unwrapped Optional Fixes

    @Test("Converts IUO to regular optional")
    func convertsIUOToOptional() {
        let (generator, tempDir) = makeGenerator(with: "var delegate: MyDelegate!")

        let smell = makeSmell(type: .implicitlyUnwrapped, line: 1, file: "test.swift")
        let result = generator.suggestFix(for: smell)

        #expect(result.canAutoFix == true)
        #expect(result.suggestion?.fixed.contains("?") == true)
        #expect(result.suggestion?.fixed.contains("!") == false)

        cleanup(tempDir)
    }

    // MARK: - Edge Cases

    @Test("Handles missing line number")
    func handlesMissingLineNumber() {
        let generator = AutoFixGenerator(projectRoot: URL(fileURLWithPath: "/tmp"))

        let smell = CodeSmell(
            file: "test.swift",
            line: nil,
            type: .forceUnwrap,
            code: "value!",
            suggestion: "",
            severity: .critical
        )

        let result = generator.suggestFix(for: smell)

        #expect(result.canAutoFix == false)
        #expect(result.reason?.contains("line number") == true)
    }

    @Test("Handles missing file")
    func handlesMissingFile() {
        let generator = AutoFixGenerator(projectRoot: URL(fileURLWithPath: "/nonexistent"))

        let smell = makeSmell(type: .forceUnwrap, line: 1, file: "missing.swift")
        let result = generator.suggestFix(for: smell)

        #expect(result.canAutoFix == false)
        #expect(result.reason?.contains("read") == true)
    }

    @Test("Returns no fix for unsupported smell types")
    func noFixForUnsupportedTypes() {
        let (generator, tempDir) = makeGenerator(with: "let x = 42")

        let smell = makeSmell(type: .magicNumber, line: 1, file: "test.swift")
        let result = generator.suggestFix(for: smell)

        #expect(result.canAutoFix == false)
        #expect(result.reason?.contains("No auto-fix") == true)

        cleanup(tempDir)
    }

    // MARK: - Helpers

    private func makeGenerator(with sourceCode: String) -> (AutoFixGenerator, URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fileURL = tempDir.appendingPathComponent("test.swift")
        try? sourceCode.write(to: fileURL, atomically: true, encoding: .utf8)

        return (AutoFixGenerator(projectRoot: tempDir), tempDir)
    }

    private func makeSmell(type: CodeSmell.SmellType, line: Int, file: String) -> CodeSmell {
        CodeSmell(
            file: file,
            line: line,
            type: type,
            code: "",
            suggestion: "",
            severity: type.severity
        )
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }
}
