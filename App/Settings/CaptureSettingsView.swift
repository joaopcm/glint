import AppKit
import ImageIO
import LunettaCore
import SwiftUI

struct CaptureSettingsView: View {
    @Bindable var settings: LunettaSettings

    var body: some View {
        Form {
            Section("Selecting") {
                Toggle(isOn: $settings.freezeScreenWhileSelecting) {
                    Text("Freeze screen while selecting")
                    Text("Takes a still of every display first, so menus and hover states hold still. The crosshair shows a moment later.")
                }
                Toggle("Show magnifier while selecting", isOn: $settings.showMagnifierWhileSelecting)
            }
            Section("Window captures") {
                Toggle(isOn: $settings.windowCaptureWallpaper) {
                    Text("Wallpaper behind window captures")
                    Text("Off keeps the window and its shadow on transparency.")
                }
                Group {
                    LabeledContent("Padding") {
                        HStack {
                            Slider(value: $settings.windowWallpaperPadding, in: LunettaSettings.windowWallpaperPaddingRange, step: 8) {
                                Text("Wallpaper padding")
                            }
                            .labelsHidden()
                            .accessibilityIdentifier(AccessibilityID.wallpaperPaddingSlider)
                            Text("\(Int(settings.windowWallpaperPadding)) pt")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                    WallpaperPaddingPreviewView(padding: settings.windowWallpaperPadding)
                        .opacity(settings.windowCaptureWallpaper ? 1 : 0.4)
                }
                .disabled(!settings.windowCaptureWallpaper)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width)
    }
}

private struct WallpaperPaddingPreviewView: View {
    let padding: Double
    @State private var wallpaper = DesktopWallpaper()

    /// Tall enough for a 400 × 240 pt sample window at 0 pt, short enough that the Capture tab fits the 768 pt CI screen.
    private static let height: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let layout = WallpaperPaddingPreview.layout(padding: padding, in: proxy.size)
                backdrop
                    .frame(width: layout.canvas.width, height: layout.canvas.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(wallpaper.image == nil ? "Padding preview on a gray gradient" : "Padding preview on your wallpaper")
                    .accessibilityIdentifier(AccessibilityID.wallpaperPaddingPreview)
                    .position(x: layout.canvas.midX, y: layout.canvas.midY)
                SampleWindow(scale: layout.scale)
                    .frame(width: layout.window.width, height: layout.window.height)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Sample window")
                    .accessibilityIdentifier(AccessibilityID.wallpaperPaddingPreviewWindow)
                    .position(x: layout.window.midX, y: layout.window.midY)
            }
            .frame(height: Self.height)
            if let failure = wallpaper.failure {
                Text("Showing a gray gradient: \(failure).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier(AccessibilityID.wallpaperPreviewFallback)
            }
        }
        .task { await wallpaper.load() }
    }

    @ViewBuilder private var backdrop: some View {
        if let image = wallpaper.image {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(colors: [Color(white: 0.62), Color(white: 0.38)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// A browser window drawn at `scale` preview points per real point, so its chrome shrinks with the padding like a real one.
private struct SampleWindow: View {
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8 * scale) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.85)).frame(width: 12 * scale, height: 12 * scale)
                }
                Capsule()
                    .fill(.quaternary)
                    .frame(maxWidth: 420 * scale, maxHeight: 24 * scale)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 14 * scale)
            .frame(height: 52 * scale)
            .background(.bar)
            VStack(alignment: .leading, spacing: 18 * scale) {
                RoundedRectangle(cornerRadius: 6 * scale).fill(.tertiary).frame(width: 520 * scale, height: 40 * scale)
                ForEach([880.0, 840, 900, 620], id: \.self) { width in
                    RoundedRectangle(cornerRadius: 4 * scale).fill(.quaternary).frame(width: width * scale, height: 16 * scale)
                }
            }
            .padding(40 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: max(10 * scale, 2)))
        .shadow(color: .black.opacity(0.35), radius: max(24 * scale, 2), y: 8 * scale)
    }
}

/// The picture on the desktop behind Settings, shrunk to preview size off the main thread.
@MainActor @Observable
private final class DesktopWallpaper {
    private(set) var image: CGImage?
    private(set) var failure: String?

    /// The preview is never wider than the Settings window; twice that covers a Retina display.
    private static let maxPixelSize = Int(SettingsLayout.width * 2)

    func load() async {
        guard let screen = NSScreen.main else {
            failure = "no display is connected"
            return
        }
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            failure = "macOS didn't say which picture is on the desktop"
            return
        }
        switch await Self.decode(url, maxPixelSize: Self.maxPixelSize) {
        case .success(let decoded):
            image = decoded
            failure = nil
        case .failure(let error):
            image = nil
            failure = error.reason
        }
    }

    struct DecodeError: Error {
        let reason: String
    }

    nonisolated private static func decode(_ url: URL, maxPixelSize: Int) async -> Result<CGImage, DecodeError> {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return .failure(DecodeError(reason: "ImageIO can't open the wallpaper at \(url.path)"))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .failure(DecodeError(reason: "ImageIO found no picture it can read in \(url.path)"))
        }
        return .success(image)
    }
}
