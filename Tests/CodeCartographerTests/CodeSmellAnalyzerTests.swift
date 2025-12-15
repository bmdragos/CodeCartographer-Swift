import Testing
import SwiftSyntax
import SwiftParser
@testable import CodeCartographer

@Suite("CodeSmellAnalyzer Tests")
struct CodeSmellAnalyzerTests {

    // MARK: - Force Unwrap Detection

    @Test("Detects force unwrap")
    func detectsForceUnwrap() {
        let code = """
        let value = optional!
        """
        let smells = analyzeCode(code)

        #expect(smells.count == 1)
        #expect(smells.first?.type == .forceUnwrap)
        #expect(smells.first?.severity == .critical)
    }

    @Test("Detects multiple force unwraps")
    func detectsMultipleForceUnwraps() {
        let code = """
        let a = optional1!
        let b = optional2!
        let c = optional3!
        """
        let smells = analyzeCode(code)

        #expect(smells.count == 3)
        #expect(smells.allSatisfy { $0.type == .forceUnwrap })
    }

    // MARK: - Force Cast Detection

    @Test("Detects force cast")
    func detectsForceCast() {
        let code = """
        func test() {
            let view = anyObject as! UIView
        }
        """
        let smells = analyzeCode(code)

        #expect(smells.contains { $0.type == .forceCast })
        #expect(smells.first { $0.type == .forceCast }?.severity == .critical)
    }

    @Test("Does not flag safe cast")
    func doesNotFlagSafeCast() {
        let code = """
        let view = anyObject as? UIView
        """
        let smells = analyzeCode(code)

        #expect(smells.filter { $0.type == .forceCast }.isEmpty)
    }

    // MARK: - Force Try Detection

    @Test("Detects force try")
    func detectsForceTry() {
        let code = """
        let data = try! loadData()
        """
        let smells = analyzeCode(code)

        #expect(smells.count == 1)
        #expect(smells.first?.type == .forceTry)
        #expect(smells.first?.severity == .critical)
    }

    @Test("Does not flag try? or do-catch")
    func doesNotFlagSafeTry() {
        let code = """
        let data = try? loadData()
        do {
            let other = try loadData()
        } catch {}
        """
        let smells = analyzeCode(code)

        #expect(smells.filter { $0.type == .forceTry }.isEmpty)
    }

    // MARK: - Empty Catch Detection

    @Test("Detects empty catch block")
    func detectsEmptyCatch() {
        let code = """
        do {
            try something()
        } catch {
        }
        """
        let smells = analyzeCode(code)

        #expect(smells.contains { $0.type == .emptycatch })
    }

    @Test("Does not flag catch with handling")
    func doesNotFlagCatchWithHandling() {
        let code = """
        do {
            try something()
        } catch {
            print(error)
        }
        """
        let smells = analyzeCode(code)

        #expect(smells.filter { $0.type == .emptycatch }.isEmpty)
    }

    // MARK: - Deep Nesting Detection

    @Test("Detects deep nesting over threshold")
    func detectsDeepNesting() {
        let code = """
        func test() {
            if a {
                if b {
                    if c {
                        if d {
                            if e {
                                print("deeply nested")
                            }
                        }
                    }
                }
            }
        }
        """
        let smells = analyzeCode(code)

        #expect(smells.contains { $0.type == .deepNesting })
    }

    @Test("Does not flag else-if chains as deep nesting")
    func doesNotFlagElseIfChains() {
        let code = """
        func test() {
            if a {
                print("a")
            } else if b {
                print("b")
            } else if c {
                print("c")
            } else if d {
                print("d")
            } else if e {
                print("e")
            } else if f {
                print("f")
            }
        }
        """
        let smells = analyzeCode(code)

        #expect(smells.filter { $0.type == .deepNesting }.isEmpty)
    }

    // MARK: - Long Parameter List Detection

    @Test("Detects long parameter list")
    func detectsLongParameterList() {
        let code = """
        func configure(a: Int, b: Int, c: Int, d: Int, e: Int, f: Int) {
        }
        """
        let smells = analyzeCode(code)

        #expect(smells.contains { $0.type == .longParameterList })
    }

    @Test("Does not flag acceptable parameter count")
    func doesNotFlagAcceptableParameterCount() {
        let code = """
        func configure(a: Int, b: Int, c: Int) {
        }
        """
        let smells = analyzeCode(code)

        #expect(smells.filter { $0.type == .longParameterList }.isEmpty)
    }

    // MARK: - Helpers

    private func analyzeCode(_ code: String) -> [CodeSmell] {
        let tree = Parser.parse(source: code)
        let visitor = CodeSmellVisitor(filePath: "test.swift", sourceText: code)
        visitor.walk(tree)
        return visitor.smells
    }
}
