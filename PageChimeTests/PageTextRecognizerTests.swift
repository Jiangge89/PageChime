import UIKit
import XCTest
@testable import PageChime

final class PageTextRecognizerTests: XCTestCase {
    /// A plain "book page" with the given lines of text.
    private func page(_ lines: [String]) -> UIImage {
        let size = CGSize(width: 1200, height: 900)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 54, weight: .regular),
                .foregroundColor: UIColor.black,
            ]
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 80, y: 100 + CGFloat(index) * 110), withAttributes: attributes)
            }
        }
    }

    func testReadsEnglishLinesInOrder() async throws {
        let text = try await VisionTextRecognizer().recognizeText(
            in: [page(["The wolf knocked on the door.", "Knock, knock!", "Who is there?"])],
            language: .english
        )
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, text)
        XCTAssertTrue(lines[0].contains("wolf knocked"), text)
        XCTAssertTrue(lines[2].contains("Who is there"), text)
    }

    func testReadsChinese() async throws {
        let text = try await VisionTextRecognizer().recognizeText(
            in: [page(["大灰狼来敲门", "小猪说不开不开"])],
            language: .chinese
        )
        XCTAssertTrue(text.contains("大灰狼"), text)
        XCTAssertTrue(text.contains("敲门"), text)
    }

    func testJoinsSeveralPages() async throws {
        let text = try await VisionTextRecognizer().recognizeText(
            in: [page(["First page"]), page([]), page(["Second page"])],
            language: .english
        )
        XCTAssertEqual(text, "First page\nSecond page")
    }
}
