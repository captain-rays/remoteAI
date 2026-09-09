import Foundation

#if canImport(ImageIO)
    import CoreGraphics
    import ImageIO
#endif

/// Where a file attached to a message lands on the Mac, and what it is called
/// when it gets there.
///
/// Both answers are the phone's to give: the agent writes wherever the upload
/// says, and the CLI is handed the resulting path. Keeping the rule in one
/// pure function means the composer, the transcript and the tests all agree
/// on it.
public enum AttachmentInbox {
    /// Inside a checkout, so `git status` shows one directory and a single
    /// `.remoteai/` line in `.gitignore` covers it.
    static let insideAProject = ".remoteai/uploads"

    /// The directory this conversation's attachments belong in.
    ///
    /// A conversation that runs in a checkout keeps its files there — that is
    /// where the CLI already is, and a relative path works. A chat that
    /// belongs to no project has no checkout to put them in, so they go to a
    /// dated inbox under Application Support, where nothing is polluted.
    public static func directory(
        for conversation: ConversationSummary,
        macHome: String,
        on day: Date,
        timeZone: TimeZone = .current
    ) -> String {
        if let root = conversation.workingPath ?? conversation.projectPath,
            !root.trimmingCharacters(in: .whitespaces).isEmpty
        {
            return "\(withoutTrailingSlash(root))/\(insideAProject)"
        }
        return "\(withoutTrailingSlash(macHome))/Library/Application Support/RemoteAI/uploads"
            + "/\(stamp(day, in: timeZone, format: "yyyy-MM-dd"))"
    }

    /// The name a picked file must be re-encoded under, or `nil` if its bytes
    /// can go over untouched.
    ///
    /// The iPhone camera writes HEIC, which the CLIs' image readers do not
    /// accept — a photo attached in that format would arrive unreadable and
    /// the reader would have no idea why. Everything else, PNG and JPEG
    /// included, travels byte for byte.
    public static func jpegName(for name: String) -> String? {
        let suffix = (name as NSString).pathExtension.lowercased()
        guard suffix == "heic" || suffix == "heif" else { return nil }
        return "\((name as NSString).deletingPathExtension).jpeg"
    }

    /// Re-encode image bytes as JPEG, or `nil` if they are not an image this
    /// device can decode.
    public static func jpegData(from data: Data, quality: Double = 0.9) -> Data? {
        #if canImport(ImageIO)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            let output = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    output as CFMutableData, "public.jpeg" as CFString, 1, nil
                )
            else { return nil }
            CGImageDestinationAddImage(
                destination, image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        #else
            return nil
        #endif
    }

    /// A name for a photo the library handed over without one.
    public static func photoName(at date: Date, extension suffix: String) -> String {
        "photo-\(stamp(date, in: .current, format: "yyyyMMdd-HHmmss")).\(suffix)"
    }

    private static func stamp(_ date: Date, in timeZone: TimeZone, format: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func withoutTrailingSlash(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespaces)
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}
