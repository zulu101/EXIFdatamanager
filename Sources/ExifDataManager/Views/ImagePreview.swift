import ExifCore
import ImageIO
import SwiftUI

/// Große Bildvorschau mit Gesichtsrahmen.
/// Ziehen mit der Maus markiert ein neues Gesicht, Klick auf einen Rahmen wählt ihn aus.
struct ImagePreview: View {
    @Bindable var item: PhotoItem
    @State private var image: NSImage?
    /// Bild so, wie es in der Datei ausgerichtet ist, und diese Ausrichtung.
    @State private var base: CGImage?
    @State private var baseOrientation = 1
    @State private var draft: CGRect?

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                if let image, let cg = item.previewImage {
                    let frame = fittedRect(for: CGSize(width: cg.width, height: cg.height), in: geometry.size)
                    canvas(image: image, size: frame.size)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                } else if let error = item.loadError {
                    ContentUnavailableView("Bild kann nicht gelesen werden", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                if item.supportsFaceRegions {
                    Image(systemName: "rectangle.dashed")
                        .foregroundStyle(.secondary)
                    Text("Rahmen um ein Gesicht ziehen, um es zu markieren")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    item.edited.rotate(clockwise: false)
                } label: {
                    Image(systemName: "rotate.left")
                }
                .buttonStyle(.borderless)
                .help("Nach links drehen (⌘L)")
                Button {
                    item.edited.rotate(clockwise: true)
                } label: {
                    Image(systemName: "rotate.right")
                }
                .buttonStyle(.borderless)
                .help("Nach rechts drehen (⌘R)")
                Divider().frame(height: 12)
                Button("In Vorschau öffnen") { NSWorkspace.shared.open(item.url) }
                    .buttonStyle(.link)
            }
            .font(.caption)
        }
        .padding()
        .background(Color(nsColor: .underPageBackgroundColor))
        .task(id: item.id) {
            let url = item.url
            let (cg, orientation) = await Task.detached(priority: .userInitiated) { () -> (CGImage?, Int) in
                let image = MetadataService.thumbnail(for: url, maxPixelSize: 2400, allowEmbedded: false)
                let props = CGImageSourceCreateWithURL(url as CFURL, nil)
                    .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [String: Any]
                return (image, props?[kCGImagePropertyOrientation as String] as? Int ?? 1)
            }.value
            base = cg
            baseOrientation = orientation
            updateDisplayedImage()
        }
        .onChange(of: item.edited.orientation) { _, _ in updateDisplayedImage() }
        .onDisappear {
            // Großes Bild nicht unnötig im Speicher halten.
            item.previewImage = nil
        }
    }

    /// Zeigt das Bild mit der (ggf. noch nicht gespeicherten) Ausrichtung an.
    private func updateDisplayedImage() {
        guard let base else { return }
        let turns = ImageOrientation.quarterTurns(from: baseOrientation, to: item.edited.orientation) ?? 0
        let shown = ImageOrientation.rotate(base, quarterTurns: turns) ?? base
        item.previewImage = shown
        image = NSImage(cgImage: shown, size: .zero)
    }

    private func canvas(image: NSImage, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: image)
                .resizable()
                .frame(width: size.width, height: size.height)
                .shadow(radius: 4)
                .onTapGesture { item.selectedFaceID = nil }

            ForEach(Array(item.edited.faces.enumerated()), id: \.element.id) { index, face in
                FaceBox(number: index + 1,
                        face: face,
                        isSelected: item.selectedFaceID == face.id,
                        hasSuggestion: item.faceSuggestions[face.id] != nil,
                        size: size,
                        onSelect: { item.selectedFaceID = face.id },
                        onDelete: { item.removeFace(face.id) })
            }

            if let draft {
                Rectangle()
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .frame(width: draft.width * size.width, height: draft.height * size.height)
                    .position(x: draft.midX * size.width, y: draft.midY * size.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .simultaneousGesture(drawGesture(size: size), including: item.supportsFaceRegions ? .all : .subviews)
    }

    private func drawGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                draft = normalizedRect(from: value.startLocation, to: value.location, size: size)
            }
            .onEnded { value in
                let rect = normalizedRect(from: value.startLocation, to: value.location, size: size)
                draft = nil
                guard rect.width > 0.015, rect.height > 0.015 else { return }
                let face = FaceRegion(rect: rect)
                item.edited.faces.append(face)
                item.selectedFaceID = face.id
            }
    }

    private func normalizedRect(from a: CGPoint, to b: CGPoint, size: CGSize) -> CGRect {
        let clamp: (CGFloat) -> CGFloat = { min(max($0, 0), 1) }
        let x1 = clamp(a.x / size.width), x2 = clamp(b.x / size.width)
        let y1 = clamp(a.y / size.height), y2 = clamp(b.y / size.height)
        return CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
    }

    private func fittedRect(for imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

/// Ein Gesichtsrahmen mit Nummer und Name.
private struct FaceBox: View {
    let number: Int
    let face: FaceRegion
    let isSelected: Bool
    let hasSuggestion: Bool
    let size: CGSize
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let r = CGRect(x: face.x * size.width, y: face.y * size.height,
                       width: face.width * size.width, height: face.height * size.height)
        let color: Color = isSelected ? .accentColor : (face.name.isEmpty ? .yellow : .white)

        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(color, style: StrokeStyle(lineWidth: isSelected ? 3 : 2, dash: face.name.isEmpty ? [5, 3] : []))
            .shadow(color: .black.opacity(0.6), radius: 1)
            .background(Color.white.opacity(0.001))
            .frame(width: r.width, height: r.height)
            .onTapGesture(perform: onSelect)
            .contextMenu { Button("Rahmen entfernen", role: .destructive, action: onDelete) }
            .position(x: r.midX, y: r.midY)

        Text(label)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(isSelected ? Color.accentColor : Color.black.opacity(0.65)))
            .foregroundStyle(.white)
            .fixedSize()
            .onTapGesture(perform: onSelect)
            .contextMenu { Button("Rahmen entfernen", role: .destructive, action: onDelete) }
            .position(x: r.midX, y: min(r.maxY + 12, size.height - 8))
    }

    private var label: String {
        let name = face.name.isEmpty ? (hasSuggestion ? "?" : String(localized: "Unbekannt")) : face.name
        return "\(number)  \(name)"
    }
}
