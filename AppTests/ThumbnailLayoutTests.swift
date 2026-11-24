import AppKit
import CoreGraphics
import GlintCore
import Testing
@testable import Glint

@MainActor @Test func thumbnailsStackUpFromTheChosenCorner() {
    let visible = CGRect(x: 0, y: 25, width: 1000, height: 800)
    let right0 = ThumbnailPresenter.frame(at: 0, in: visible, corner: .bottomRight, collapsed: false, width: 240)!
    let right1 = ThumbnailPresenter.frame(at: 1, in: visible, corner: .bottomRight, collapsed: false, width: 240)!
    let left0 = ThumbnailPresenter.frame(at: 0, in: visible, corner: .bottomLeft, collapsed: false, width: 240)!

    #expect(right0 == CGRect(x: 1000 - 16 - 240, y: 25 + 16, width: 240, height: 160))
    #expect(right1.minY == right0.maxY + 10)
    #expect(right1.minX == right0.minX)
    #expect(left0.minX == 16)
    #expect(!right0.intersects(right1))
}

@MainActor @Test func collapsedPileShowsThreeCardsInTheCorner() {
    let visible = CGRect(x: 0, y: 25, width: 1000, height: 800)
    let front = ThumbnailPresenter.frame(at: 0, in: visible, corner: .bottomRight, collapsed: true, width: 240)!
    let behind = ThumbnailPresenter.frame(at: 1, in: visible, corner: .bottomRight, collapsed: true, width: 240)!

    #expect(front == ThumbnailPresenter.frame(at: 0, in: visible, corner: .bottomRight, collapsed: false, width: 240))
    #expect(behind.midX == front.midX && behind.width < front.width)
    #expect(behind.maxY > front.maxY) // peeks out above the front card
    #expect(ThumbnailPresenter.frame(at: 2, in: visible, corner: .bottomRight, collapsed: true, width: 240) != nil)
    #expect(ThumbnailPresenter.frame(at: 3, in: visible, corner: .bottomRight, collapsed: true, width: 240) == nil)
}

@MainActor @Test func edgeDragGrowsAwayFromTheCornerAndFollowsTheDominantAxis() {
    let up30 = CGSize(width: 0, height: 30)
    #expect(ThumbnailPresenter.resizedWidth(start: 240, translation: up30, corner: .bottomRight) == 285) // 30 × 1.5
    #expect(ThumbnailPresenter.resizedWidth(start: 240, translation: up30, corner: .bottomLeft) == 285)

    let left40 = CGSize(width: -40, height: 0)
    #expect(ThumbnailPresenter.resizedWidth(start: 240, translation: left40, corner: .bottomRight) == 280)
    #expect(ThumbnailPresenter.resizedWidth(start: 240, translation: left40, corner: .bottomLeft) == 200)

    let mostlyDown = CGSize(width: -10, height: -20) // vertical (-30) beats horizontal (+10)
    #expect(ThumbnailPresenter.resizedWidth(start: 240, translation: mostlyDown, corner: .bottomRight) == 210)
}

@MainActor @Test func savedWidthSizesBothThePileAndTheColumn() {
    let visible = CGRect(x: 0, y: 25, width: 1000, height: 800)
    let front = ThumbnailPresenter.frame(at: 0, in: visible, corner: .bottomRight, collapsed: true, width: 360)!
    let second = ThumbnailPresenter.frame(at: 1, in: visible, corner: .bottomRight, collapsed: false, width: 360)!

    #expect(front.size == CGSize(width: 360, height: 240))
    #expect(front.maxX == visible.maxX - ThumbnailPresenter.margin) // still pinned to the corner
    #expect(second.width == 360 && second.minY == front.maxY + 10)
}

@MainActor @Test func showDropsOldestWhenTheColumnWouldOverflow() throws {
    let screen = try #require(NSScreen.main)
    let settings = GlintSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)
    let presenter = ThumbnailPresenter(settings: settings, upload: noUpload, onUploaded: { _ in }, pointerLocation: { CGPoint(x: screen.frame.midX, y: screen.frame.midY) })
    let fit = ThumbnailPresenter.columnCapacity(in: screen.visibleFrame, width: GlintSettings.defaultThumbnailWidth)
    let files = try (0..<(fit + 2)).map { _ in try writePNG() }

    files.forEach(presenter.show)

    #expect(presenter.count == fit)
    #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
}

@MainActor @Test func growingTheCardsDropsOldestWhenTheColumnWouldOverflow() throws {
    let screen = try #require(NSScreen.main)
    let settings = GlintSettings(store: Defaults(), defaultSaveFolder: FileManager.default.temporaryDirectory)
    let presenter = ThumbnailPresenter(settings: settings, upload: noUpload, onUploaded: { _ in }, pointerLocation: { CGPoint(x: screen.frame.midX, y: screen.frame.midY) })
    let widest = GlintSettings.thumbnailWidthRange.upperBound
    let fit = ThumbnailPresenter.columnCapacity(in: screen.visibleFrame, width: GlintSettings.defaultThumbnailWidth)
    let fitWhenWidest = ThumbnailPresenter.columnCapacity(in: screen.visibleFrame, width: widest)
    try #require(fitWhenWidest < fit)
    let files = try (0..<fit).map { _ in try writePNG() }
    files.forEach(presenter.show)
    #expect(presenter.count == fit)

    settings.thumbnailWidth = widest
    presenter.settingsChanged()

    #expect(presenter.count == fitWhenWidest)
    #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
}
