import Testing
import Foundation
@testable import LLMDesigner

@Suite("Formel → Python")
struct MathPythonTests {
    private func python(_ latex: String) throws -> String {
        try MathPythonTranslator.translate(latex: latex).text
    }

    @Test func energy() throws {
        let code = try python("E = m c^2")
        #expect(code == "def E(m, c):\n    r\"\"\"E=mc^2\"\"\"\n    return m * c ** 2")
    }

    @Test func functionDefinition() throws {
        let code = try python("f(x) = \\frac{x^2 + 1}{2x} - \\sqrt{x}")
        #expect(code.contains("def f(x):"))
        #expect(code.contains("return (x ** 2 + 1) / (2 * x) - math.sqrt(x)"))
        #expect(code.hasPrefix("import math"))
    }

    @Test func quadraticFormula() throws {
        let code = try python("x_{1,2} = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}")
        #expect(code.contains("def x(b, a, c):") || code.contains("def x(a, b, c):") || code.contains("def x("))
        #expect(code.contains("return (-b + math.sqrt(b ** 2 - 4 * a * c)) / (2 * a), (-b - math.sqrt(b ** 2 - 4 * a * c)) / (2 * a)"))
    }

    @Test func sumAndProduct() throws {
        let sum = try python("S = \\sum_{k=1}^{n} k^2")
        #expect(sum.contains("return sum(k ** 2 for k in range(1, n + 1))"))
        let product = try python("P = \\prod_{k=1}^{n} k")
        #expect(product.contains("math.prod(k for k in range(1, n + 1))"))
    }

    @Test func integral() throws {
        let code = try python("F(x) = \\int_0^x t^2 \\, dt")
        #expect(code.hasPrefix("import math\n") == false)
        #expect(code.contains("from scipy.integrate import quad"))
        #expect(code.contains("return quad(lambda t: t ** 2, 0, x)[0]"))
    }

    @Test func piecewise() throws {
        let code = try python("f(x) = \\begin{cases} x^2 & x < 0 \\\\ 2x & 0 \\le x < 1 \\\\ 1 & \\text{sonst} \\end{cases}")
        #expect(code.contains("x ** 2 if x < 0 else 2 * x if 0 <= x < 1 else 1"))
    }

    @Test func steps() throws {
        let code = try python("\\Delta = b^2 - 4ac \\\\ x = \\frac{-b + \\sqrt{\\Delta}}{2a}")
        #expect(code.contains("Delta = b ** 2 - 4 * a * c"))
        #expect(code.contains("x = (-b + math.sqrt(Delta)) / (2 * a)"))
        #expect(code.contains("return x"))
    }

    @Test func equationAndComparison() throws {
        #expect(try python("x^2 + y^2 = 1").contains("return x ** 2 + y ** 2 - 1"))
        #expect(try python("x^2 + y^2 \\le 1").contains("return x ** 2 + y ** 2 <= 1"))
    }

    @Test func precedence() throws {
        #expect(try python("g(a, b) = a - (b - 1)").contains("return a - (b - 1)"))
        #expect(try python("g(a, b) = \\frac{a}{b c}").contains("return a / (b * c)"))
        #expect(try python("g(a) = -a^2").contains("return -a ** 2"))
        #expect(try python("g(a) = (-a)^2").contains("return (-a) ** 2"))
        #expect(try python("g(a) = e^{-a}").contains("math.e ** (-a)") || python("g(a) = e^{-a}").contains("math.e ** -a"))
    }

    @Test func greekAndSubscripts() throws {
        let code = try python("v = \\lambda f")
        #expect(code.contains("def v(lambda_, f):"))
        #expect(code.contains("return lambda_ * f"))
        #expect(try python("y = a_1 x + a_0").contains("def y(a_1, x, a_0):"))
    }

    @Test func unsupported() {
        #expect(throws: MathPythonError.self) { try MathPythonTranslator.translate(latex: "\\lim_{x \\to 0} \\frac{\\sin x}{x}") }
        #expect(throws: MathPythonError.self) { try MathPythonTranslator.translate(latex: "\\vec{v} = (1, 2)") }
        #expect(throws: MathPythonError.self) { try MathPythonTranslator.translate(latex: "") }
    }
}
