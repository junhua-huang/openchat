import XCTest
import UIKit
import SwiftMath
@testable import LiaoChat

final class MathTests: XCTestCase {
    @MainActor func testRasterOrientationMatchesNativeMathImage() throws {
        let expression = MathExpression(latex: "F", display: false, source: "$F$")
        let actual = try XCTUnwrap(MathRenderer.raster(expression, size: 24, scale: 2)?.image)
        let reference = MTMathImage(latex: "F", fontSize: 24, textColor: .black, labelMode: .text, textAlignment: .left)
        reference.contentInsets = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        let expected = try XCTUnwrap(reference.asImage().1)
        func centroid(_ image: UIImage) throws -> Double {
            let cgImage = try XCTUnwrap(image.cgImage)
            var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
            return try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 64, height: 64,
                    bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 64, height: 64))
                let values = bytes.bindMemory(to: UInt8.self)
                var weight = 0.0; var moment = 0.0
                for y in 0..<64 {
                    for x in 0..<64 {
                        let alpha = Double(values[(y * 64 + x) * 4 + 3])
                        weight += alpha; moment += alpha * Double(y)
                    }
                }
                XCTAssertGreaterThan(weight, 0)
                return moment / max(weight, 1) / 64
            }
        }
        XCTAssertEqual(try centroid(actual), try centroid(expected), accuracy: 0.04)
    }
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
            if let image = raster?.image.cgImage {
                var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
                let hasInk = pixels.withUnsafeMutableBytes { bytes -> Bool in
                    guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32,
                        bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                    context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
                    let values = bytes.bindMemory(to: UInt8.self)
                    return stride(from: 3, to: values.count, by: 4).contains { values[$0] > 0 }
                }
                XCTAssertTrue(hasInk, "Formula must contain visible glyphs: " + latex)
            } else { XCTFail("Missing formula bitmap") }
            XCTAssertTrue(raster === MathRenderer.raster(expression, size: 19, scale: 2))
        }
    }

    @MainActor func testUnsupportedOrOversizedFormulaFallsBackWithoutRendering() {
        for latex in [#"\unknowncommand{x}"#, #"\frac{"#, String(repeating: "x", count: 8_193)] {
            XCTAssertNil(MathRenderer.raster(MathExpression(latex: latex, display: false, source: "$" + latex + "$"), size: 17, scale: 2))
        }
    }
}
