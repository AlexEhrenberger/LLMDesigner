import AppKit
import ImageIO
import SwiftUI

/// Scaled copies of attached pictures for display, kept in memory.
@MainActor
enum ThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func cached(_ attachment: ImageAttachment, pixels: Int) -> NSImage? {
        cache.object(forKey: key(attachment, pixels))
    }

    static func load(_ attachment: ImageAttachment, pixels: Int) async -> NSImage? {
        if let image = cached(attachment, pixels: pixels) { return image }
        let url = AttachmentStore.url(for: attachment)
        let scaled = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        guard let scaled else { return nil }
        let image = NSImage(cgImage: scaled, size: NSSize(width: scaled.width, height: scaled.height))
        cache.setObject(image, forKey: key(attachment, pixels))
        return image
    }

    private static func key(_ attachment: ImageAttachment, _ pixels: Int) -> NSString {
        "\(attachment.fileName)@\(pixels)" as NSString
    }
}

/// An attached picture, loaded in the background at a size that fits where it is shown.
struct AttachmentImage: View {
    let attachment: ImageAttachment
    /// Longest side in pixels of the copy that is loaded.
    let pixels: Int
    @State private var image: NSImage?

    var body: some View {
        // Takes exactly the offered size and crops the picture to it.
        Color.clear
            .overlay {
                if let image = image ?? ThumbnailCache.cached(attachment, pixels: pixels) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Theme.elevated
                }
            }
            .clipped()
            .task(id: attachment.fileName) {
            image = await ThumbnailCache.load(attachment, pixels: pixels)
        }
    }
}

/// Pictures waiting to be sent, in the composer or in the editor of a sent question.
struct AttachmentStrip: View {
    let images: [ImageAttachment]
    /// Pictures that are still being read; shown as placeholders.
    let importing: Int
    let onRemove: (ImageAttachment.ID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(images) { image in
                    RemovableThumbnail(attachment: image) { onRemove(image.id) }
                }
                ForEach(0..<importing, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.elevated)
                        .frame(width: 58, height: 58)
                        .overlay(ProgressView().controlSize(.small))
                }
            }
            // Room for the remove buttons, which stick out at the top right.
            .padding(.top, 6)
            .padding(.trailing, 6)
        }
        .animation(.easeOut(duration: 0.15), value: images)
    }
}

private struct RemovableThumbnail: View {
    let attachment: ImageAttachment
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        AttachmentImage(attachment: attachment, pixels: 180)
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.strongBorder))
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.black.opacity(0.8)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .opacity(hovering ? 1 : 0.8)
                .help("Bild entfernen")
            }
            .onHover { hovering = $0 }
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// Pictures of a sent question, above its bubble. A click opens the picture in Preview.
struct MessageImageGallery: View {
    let images: [ImageAttachment]

    var body: some View {
        if images.count == 1, let image = images.first {
            let size = Self.fitted(image, in: CGSize(width: 320, height: 260))
            GalleryImage(attachment: image, pixels: 800)
                .frame(width: size.width, height: size.height)
        } else {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(Array(stride(from: 0, to: images.count, by: 3)), id: \.self) { start in
                    HStack(spacing: 8) {
                        ForEach(images[start..<min(start + 3, images.count)]) { image in
                            GalleryImage(attachment: image, pixels: 360)
                                .frame(width: 132, height: 132)
                        }
                    }
                }
            }
        }
    }

    private static func fitted(_ image: ImageAttachment, in bounds: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return bounds }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height), 1)
        return CGSize(width: max(CGFloat(image.width) * scale, 60), height: max(CGFloat(image.height) * scale, 60))
    }
}

private struct GalleryImage: View {
    let attachment: ImageAttachment
    let pixels: Int
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(AttachmentStore.url(for: attachment))
        } label: {
            AttachmentImage(attachment: attachment, pixels: pixels)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
                .brightness(hovering ? 0.04 : 0)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("In Vorschau öffnen")
    }
}
