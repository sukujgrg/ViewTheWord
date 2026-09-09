import AppKit

/// Measure the actual script with AppKit, then fit within the space allocated by SwiftUI.
enum ProjectorTextLayout {
    static func fontSize(for text: String, in size: CGSize, preferred: CGFloat) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        let available = CGSize(width: max(1, floor(size.width)), height: max(1, floor(size.height)))
        var low: CGFloat = 1
        var high = max(1, min(preferred, 200))
        for _ in 0..<12 {
            let candidate = (low + high) / 2
            let bounds = measuredSize(text, width: available.width, fontSize: candidate)
            if bounds.height <= available.height && bounds.width <= available.width { low = candidate }
            else { high = candidate }
        }
        return low
    }
    static func measuredSize(_ text: String, width: CGFloat, fontSize: CGFloat) -> CGSize {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .heavy), .paragraphStyle: paragraph]
        )
        return CGSize(width: bounds.width, height: ceil(bounds.height))
    }
}
