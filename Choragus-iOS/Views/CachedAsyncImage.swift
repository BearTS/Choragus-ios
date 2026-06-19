import SwiftUI
import SonosKit

struct CachedAsyncImage: View {
    let url: URL?
    var cornerRadius: CGFloat = 8

    @State private var image: UIImage?

    private var cachedImage: UIImage? {
        guard let url else { return nil }
        return ImageCache.shared.image(for: url)
    }

    var body: some View {
        Group {
            if let img = image ?? cachedImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .onAppear { loadImage() }
        .onChange(of: url) { loadImage() }
    }

    private func loadImage() {
        guard let url else { image = nil; return }
        if let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }
        image = nil
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let loaded = UIImage(data: data) else { return }
            let squared = cropToSquare(loaded)
            ImageCache.shared.store(squared, for: url)
            await MainActor.run { image = squared }
        }
    }

    private func cropToSquare(_ source: UIImage) -> UIImage {
        let size = source.size
        guard size.width != size.height, size.width > 0, size.height > 0 else { return source }
        let side = min(size.width, size.height)
        let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
        let cropRect = CGRect(origin: origin, size: CGSize(width: side, height: side))
        guard let cgImage = source.cgImage?.cropping(to: cropRect) else { return source }
        return UIImage(cgImage: cgImage)
    }
}
