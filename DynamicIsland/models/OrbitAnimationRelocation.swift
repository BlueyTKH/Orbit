import Foundation

/// Keep selected/imported animation identities and transforms while their files move.
enum OrbitAnimationRelocation {
    static func relocate(_ animation: CustomIdleAnimation, bundledFiles: [String: URL], legacySupport: URL, support: URL) -> CustomIdleAnimation {
        guard case .lottieFile(let url) = animation.source, url.isFileURL else { return animation }
        var result = animation
        if animation.isBuiltIn, let replacement = bundledFiles[url.lastPathComponent] {
            result.source = .lottieFile(replacement)
        } else {
            let prefix = legacySupport.standardizedFileURL.path + "/"
            if url.standardizedFileURL.path.hasPrefix(prefix) {
                let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count))
                result.source = .lottieFile(support.appendingPathComponent(relative))
            }
        }
        return result
    }
}
