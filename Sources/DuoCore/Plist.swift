import Foundation

/// Reads and writes Info.plist / InfoPlist.strings. InfoPlist.strings uses the OpenStep text format, which
/// PropertyListSerialization can read; everything is written back as XML (same as `plutil -convert xml1`).
enum Plist {
    static func read(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    static func write(_ dict: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    static func string(_ url: URL, _ key: String) -> String? {
        read(url)?[key] as? String
    }

    /// Applies changes; a `nil` value deletes the key. Returns whether the file was written.
    @discardableResult
    static func update(_ url: URL, onlyExisting: Bool = false, _ changes: [String: String?]) throws -> Bool {
        guard var dict = read(url) else { throw DuoError("Cannot read \(url.path)") }
        var changed = false
        for (key, value) in changes {
            if let value {
                if onlyExisting && dict[key] == nil { continue }
                if dict[key] as? String != value { dict[key] = value; changed = true }
            } else if dict.removeValue(forKey: key) != nil {
                changed = true
            }
        }
        if changed { try write(dict, to: url) }
        return changed
    }
}
