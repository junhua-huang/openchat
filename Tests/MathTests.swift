import XCTest
import UIKit
@testable import LiaoChat

final class MathTests: XCTestCase {
    private func formula(_ source: String, _ latex: String, display: Bool = false) -> MathPart {
        .math(MathExpression(latex: latex, display: display, source: source))
    }

    func testBothInlineDelimitersPreserveCommandsAndSurroundingMarkdown() {
        XCTAssertEqual(MessageMath.parts(#"中文 **重点** $x_1^2$ 和 \(\frac{x}{1-0.01y}\)。"#), [
            .text("中文 **重点** "), formula("$x_1^2$", "x_1^2"), .text(" 和 "),
            formula(#"\(\frac{x}{1-0.01y}\)"#, #"\frac{x}{1-0.01y}"#), .text("。")
        ])
    }

    func testMultilineDisplayMathDoesNotBecomeTableOrList() {
        let latex = #"\begin{pmatrix}a & b \\ c & d\end{pmatrix}"#
        let source = "$$\n" + latex + "\n$$"
        XCTAssertEqual(MessageContent.blocks("前文\n" + source + "\n后文"), [
            .prose("前文"), .math(MathExpression(latex: latex, display: true, source: source)), .prose("后文")
        ])
        XCTAssertEqual(MessageMath.parts(#"\[\sum_{i=1}^n i\]"#), [
            formula(#"\[\sum_{i=1}^n i\]"#, #"\sum_{i=1}^n i"#, display: true)
        ])
    }

    func testInlineCodeFencesAndLinkDestinationsAreProtected() {
        let source = #"`$x$` ``\(y\)`` [链接](https://example.com/$a$) 与 $z$"#
        XCTAssertEqual(MessageMath.parts(source), [
            .text(#"`$x$` ``\(y\)`` [链接](https://example.com/$a$) 与 "#), formula("$z$", "z")
        ])
        let code = "```latex\n$$x^2$$\n\\(y\\)\n```"
        XCTAssertEqual(MessageContent.blocks(code), [.code(language: "latex", text: "$$x^2$$\n\\(y\\)")])
    }

    func testEscapedDollarsPricesAndUnfinishedStreamingRemainText() {
        for source in [#"价格 \$5 和 \$10"#, "价格 $5 和 $10", "$x +", "$$x", #"\[\frac{a}{"#, #"\(x"#, "$$ $$"] {
            XCTAssertEqual(MessageMath.parts(source), [.text(source)], source)
        }
        XCTAssertEqual(MessageMath.parts("$2$"), [formula("$2$", "2")])
        XCTAssertEqual(MessageMath.parts(#"$x+\$y$"#), [formula(#"$x+\$y$"#, #"x+\$y"#)])
    }

    func testEveryStreamingPrefixRetainsOriginalCharacters() {
        let source = #"中文🙂 \[\frac{x}{1-y}\] 后文 $z_1$"#
        for end in source.indices {
            let prefix = String(source[..<end])
            let restored = MessageMath.parts(prefix).map { part in
                switch part { case .text(let value): return value; case .math(let value): return value.source }
            }.joined()
            XCTAssertEqual(restored, prefix)
        }
    }

    func testTablesKeepLatexBackslashesAndRowSeparators() {
        XCTAssertEqual(MessageContent.tableCells(#"| $|x|$ | \(\left\|x\right\|\) |"#), [
            "$|x|$", #"\(\left\|x\right\|\)"#
        ])
        XCTAssertEqual(MessageContent.tableCells(#"| \(\frac{a}{b}\) | $\begin{matrix}a\\b\end{matrix}$ | A\|B |"#), [
            #"\(\frac{a}{b}\)"#, #"$\begin{matrix}a\\b\end{matrix}$"#, "A|B"
        ])
    }

    @MainActor func testNativeRenderingFractionsRootsSumsAndMatrices() {
        for latex in [#"\frac{x}{1-0.01y}"#, #"\sqrt{x^2+y^2}"#, #"\sum_{i=1}^{n} i"#,
                      #"\begin{pmatrix}a & b \\ c & d\end{pmatrix}"#] {
            let expression = MathExpression(latex: latex, display: true, source: "$$" + latex + "$$")
            let raster = MathRenderer.raster(expression, size: 19, scale: 2)
            XCTAssertNotNil(raster, latex)
            XCTAssertGreaterThan(raster?.image.size.width ?? 0, 5)
            XCTAssertGreaterThan(raster?.image.size.height ?? 0, 5)
            XCTAssertGreaterThan(raster?.descent ?? 0, 0)
            XCTAssertTrue(raster === MathRenderer.raster(expression, size: 19, scale: 2))
        }
    }

    @MainActor func testUnsupportedOrOversizedFormulaFallsBackWithoutRendering() {
        for latex in [#"\unknowncommand{x}"#, #"\frac{"#, String(repeating: "x", count: 8_193)] {
            XCTAssertNil(MathRenderer.raster(MathExpression(latex: latex, display: false, source: "$" + latex + "$"), size: 17, scale: 2))
        }
    }
}
