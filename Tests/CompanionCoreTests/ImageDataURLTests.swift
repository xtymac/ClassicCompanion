import XCTest
@testable import CompanionCore

final class ImageDataURLTests: XCTestCase {
    func testDecodesPercentEncodedSVG() {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"/>"
        let encoded = svg.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let payload = ImageDataURL.decode(URL(string: "data:image/svg+xml;utf8,\(encoded)"))
        XCTAssertEqual(payload?.mimeType, "image/svg+xml")
        XCTAssertEqual(payload.map { String(decoding: $0.data, as: UTF8.self) }, svg)
    }

    func testDecodesBase64() {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF])
        let payload = ImageDataURL.decode(URL(string: "data:IMAGE/PNG;base64,\(bytes.base64EncodedString())"))
        XCTAssertEqual(payload, ImageDataURL.Payload(mimeType: "image/png", data: bytes))
    }

    func testRejectsEverythingElse() {
        XCTAssertNil(ImageDataURL.decode(nil))
        XCTAssertNil(ImageDataURL.decode(URL(string: "https://chatgpt.com/a.png")))
        XCTAssertNil(ImageDataURL.decode(URL(string: "data:text/html,%3Cscript%3E1%3C/script%3E")), "只显示图片")
        XCTAssertNil(ImageDataURL.decode(URL(string: "data:,hello")))
        XCTAssertNil(ImageDataURL.decode(URL(string: "data:image/x-unknown;base64,AQID")), "只认列出的图片类型")
        XCTAssertNil(ImageDataURL.decode(URL(string: "data:image/svg+xml%22%3E%3Cscript%3E;base64,AQID")))
        XCTAssertNil(ImageDataURL.decode(URL(string: "data:image/png;base64,")))
        XCTAssertNil(ImageDataURL.decode(URL(string: "blob:https://chatgpt.com/1234")))
    }
}
