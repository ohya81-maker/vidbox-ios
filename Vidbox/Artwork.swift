import SwiftUI
import UIKit

extension VideoItem {
    /// 고화질 표지 후보 (앞에서부터 시도)
    /// - YouTube Music 앨범아트(googleusercontent)는 1200px로 다시 요청
    /// - 일반 영상은 maxresdefault(1280x720) → sddefault(640x480) → hq720 → 기존 썸네일
    var artworkCandidates: [URL] {
        var list: [URL] = []
        if let t = thumbnail, let host = t.host, host.contains("googleusercontent") || host.contains("ggpht") {
            let s = t.absoluteString
            if let range = s.range(of: #"=w\d+-h\d+[^&]*$"#, options: .regularExpression),
               let big = URL(string: s.replacingCharacters(in: range, with: "=w1200-h1200-l90-rj")) {
                list.append(big)
            }
        }
        for name in ["maxresdefault.jpg", "hq720.jpg", "sddefault.jpg"] {
            if let url = URL(string: "https://i.ytimg.com/vi/\(id)/\(name)") { list.append(url) }
        }
        list.append(bestThumbnail)
        return list
    }
}

/// 후보 URL을 차례로 받아 보고, 실제로 존재하는 가장 큰 이미지를 고른다 (메모리 캐시)
actor ArtworkLoader {
    static let shared = ArtworkLoader()
    private let cache = NSCache<NSString, UIImage>()

    func image(for item: VideoItem) async -> UIImage? {
        if let cached = cache.object(forKey: item.id as NSString) { return cached }
        for url in item.artworkCandidates {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data),
                  image.size.width >= 320 // YouTube가 없는 화질 대신 주는 120px 회색 이미지는 건너뜀
            else { continue }
            cache.setObject(image, forKey: item.id as NSString)
            return image
        }
        return nil
    }
}

/// 고화질 표지 뷰. 받기 전에는 기존 썸네일을 먼저 보여준다.
struct HiResArtwork: View {
    let item: VideoItem
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                AsyncImage(url: item.bestThumbnail) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: contentMode)
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
            }
        }
        .task(id: item.id) {
            image = nil
            image = await ArtworkLoader.shared.image(for: item)
        }
    }
}
