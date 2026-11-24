import CoreGraphics
import XCTest

@testable import UDaSnapCore

final class AnnotationModelTests: XCTestCase {

    private func makeImage(width: Int = 100, height: Int = 80) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func makeDocument() -> AnnotationDocument {
        AnnotationDocument(image: makeImage(), contentScale: 2)
    }

    func testNextNumberStartsAtOneAndIncrements() {
        var document = makeDocument()
        XCTAssertEqual(document.nextNumber, 1)
        document.add(
            AnnotationObject(
                frame: CGRect(x: 2, y: 2, width: 20, height: 20),
                kind: .number(1),
                style: AnnotationStyle()))
        XCTAssertEqual(document.nextNumber, 2)
        document.add(
            AnnotationObject(
                frame: CGRect(x: 30, y: 2, width: 20, height: 20),
                kind: .number(7),
                style: AnnotationStyle()))
        XCTAssertEqual(document.nextNumber, 8)
    }

    func testCheckpointUndoRedoRestoresObjects() {
        var document = makeDocument()
        document.checkpoint()
        let object = AnnotationObject(
            frame: CGRect(x: 10, y: 10, width: 20, height: 10),
            kind: .rectangle,
            style: AnnotationStyle())
        document.add(object)
        XCTAssertEqual(document.objects.count, 1)
        XCTAssertTrue(document.canUndo)

        document.undo()
        XCTAssertTrue(document.objects.isEmpty)
        XCTAssertTrue(document.canRedo)

        document.redo()
        XCTAssertEqual(document.objects.count, 1)
    }

    func testCropShiftsObjectsAndKeepsOutsideObjects() {
        var document = makeDocument()
        let object = AnnotationObject(
            frame: CGRect(x: 20, y: 30, width: 30, height: 20),
            kind: .rectangle,
            style: AnnotationStyle())
        document.add(object)

        XCTAssertTrue(document.crop(to: CGRect(x: 10, y: 10, width: 50, height: 40)))
        XCTAssertEqual(document.canvasSize, CGSize(width: 50, height: 40))
        XCTAssertEqual(document.objects[0].frame.origin, CGPoint(x: 10, y: 20))
        XCTAssertEqual(document.objects[0].frame.size, CGSize(width: 30, height: 20))
    }

    func testRotateClockwiseTransformsGeometry() {
        var document = makeDocument()
        document.add(
            AnnotationObject(
                frame: CGRect(x: 10, y: 20, width: 30, height: 40),
                kind: .rectangle,
                style: AnnotationStyle()))
        let text = AnnotationObject(
            frame: CGRect(x: 40, y: 10, width: 20, height: 12),
            kind: .text("A"),
            style: AnnotationStyle())
        document.add(text)

        XCTAssertTrue(document.rotate(clockwise: true))
        XCTAssertEqual(document.canvasSize, CGSize(width: 80, height: 100))
        XCTAssertEqual(document.objects[0].frame, CGRect(x: 20, y: 10, width: 40, height: 30))
        XCTAssertEqual(document.objects[1].frame.size, CGSize(width: 20, height: 12))
        XCTAssertEqual(document.objects[1].frame.midX, 64)
        XCTAssertEqual(document.objects[1].frame.midY, 50)
    }

    func testFlipHorizontallyMirrorsGeometry() {
        var document = makeDocument()
        document.add(
            AnnotationObject(
                frame: CGRect(x: 10, y: 20, width: 30, height: 40),
                kind: .rectangle,
                style: AnnotationStyle()))
        XCTAssertTrue(document.flipHorizontally())
        XCTAssertEqual(document.objects[0].frame, CGRect(x: 60, y: 20, width: 30, height: 40))
    }

    func testHitTestUsesTopmostObject() {
        var document = makeDocument()
        let lower = AnnotationObject(
            frame: CGRect(x: 0, y: 0, width: 50, height: 50),
            kind: .rectangle,
            style: AnnotationStyle())
        let upper = AnnotationObject(
            frame: CGRect(x: 10, y: 10, width: 20, height: 20),
            kind: .ellipse,
            style: AnnotationStyle())
        document.add(lower)
        document.add(upper)
        XCTAssertEqual(document.hitTest(CGPoint(x: 15, y: 15), tolerance: 0), 1)
        XCTAssertEqual(document.hitTest(CGPoint(x: 45, y: 45), tolerance: 0), 0)
        XCTAssertNil(document.hitTest(CGPoint(x: 70, y: 70), tolerance: 0))
    }
}
