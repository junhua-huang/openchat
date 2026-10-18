import SwiftUI
import UIKit
import SwiftMath

// Template images inherit the surrounding Text color, including dark mode and
// secondary quote text. Cache by formula, type size and screen scale while streaming.
@MainActor enum MathRenderer {
    final class Raster: NSObject {
        let image: UIImage
        let descent: CGFloat
        init(image: UIImage, descent: CGFloat) { self.image = image; self.descent = descent }
    }
    private static let cache: NSCache<NSString, Raster> = {
        let cache = NSCache<NSString, Raster>()
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    static func raster(_ expression: MathExpression, size: CGFloat, scale: CGFloat) -> Raster? {
        // Bound work and bitmap allocation for model-generated input.
        guard expression.latex.count <= 8_192 else { return nil }
        let key = "\(expression.display)|\(size)|\(scale)|\(expression.latex)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let label = MTMathUILabel()
        label.displayErrorInline = false
        label.fontSize = size
        label.labelMode = expression.display ? .display : .text
        label.textColor = .black
        label.contentInsets = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        label.latex = expression.latex
        guard label.error == nil else { return nil }
        let natural = label.sizeThatFits(.zero)
        let bounds = CGSize(width: ceil(natural.width), height: ceil(natural.height))
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width * bounds.height * scale * scale <= 4_000_000 else { return nil }
        label.frame = CGRect(origin: .zero, size: bounds)
        label.setNeedsLayout(); label.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale; format.opaque = false
        let image = UIGraphicsImageRenderer(size: bounds, format: format).image { context in
            label.layer.render(in: context.cgContext)
        }.withRenderingMode(.alwaysTemplate)
        let baseline = label.displayList?.position.y ?? 2
        let raster = Raster(image: image, descent: baseline)
        cache.setObject(raster, forKey: key, cost: Int(bounds.width * bounds.height * scale * scale * 4))
        return raster
    }
}

struct MathText: View {
    let value: String
    @ScaledMetric private var fontSize: CGFloat
    @Environment(\.displayScale) private var scale

    init(_ value: String, size: CGFloat = 17, relativeTo font: Font.TextStyle = .body) {
        self.value = value
        _fontSize = ScaledMetric(wrappedValue: size, relativeTo: font)
    }

    var body: some View { rendered }

    private var rendered: Text {
        var markdown = ""
        var expressions: [(String, MathExpression)] = []
        var prefix = "\u{E000}math"
        while value.contains(prefix) { prefix += "x" }
        for part in MessageMath.parts(value) {
            switch part {
            case .text(let value): markdown += value
            case .math(let expression):
                let token = "\(prefix)\(expressions.count)\u{E001}"
                markdown += token; expressions.append((token, expression))
            }
        }
        let attributed = (try? AttributedString(markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
        var result = Text("")
        var cursor = attributed.startIndex
        for (token, expression) in expressions {
            guard let range = attributed.range(of: token), range.lowerBound >= cursor else { continue }
            result = result + Text(AttributedString(attributed[cursor..<range.lowerBound]))
            if let raster = MathRenderer.raster(expression, size: fontSize, scale: scale) {
                result = result + Text(Image(uiImage: raster.image)).baselineOffset(-raster.descent)
                    .accessibilityLabel(Text(expression.latex))
            } else { result = result + Text(verbatim: expression.source) }
            cursor = range.upperBound
        }
        return result + Text(AttributedString(attributed[cursor...]))
    }
}

struct DisplayMathView: View {
    let expression: MathExpression
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 19
    @Environment(\.displayScale) private var scale

    var body: some View {
        ScrollView(.horizontal) {
            Group {
                if let raster = MathRenderer.raster(expression, size: fontSize, scale: scale) {
                    Image(uiImage: raster.image).renderingMode(.template).accessibilityLabel(expression.latex)
                } else { Text(verbatim: expression.source).font(.system(.body, design: .monospaced)) }
            }.padding(.vertical, 4)
        }
        .accessibilityIdentifier("chat.math.display")
        .contextMenu {
            Button("复制公式", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = expression.source; TouchFeedback.tap()
            }
        }
    }
}
