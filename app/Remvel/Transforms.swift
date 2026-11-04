import Foundation

/// Text changes offered by the action panel (⌘K): the result is pasted, the history item stays as it was.
/// Each returns nil when it does not apply, e.g. Format JSON on text that is not JSON.
struct Transform {
    let title: String
    let apply: (String) -> String?

    static let all: [[Transform]] = [
        [
            Transform(title: "UPPERCASE") { $0.uppercased() },
            Transform(title: "lowercase") { $0.lowercased() },
            Transform(title: "Title Case") { $0.capitalized },
            Transform(title: "camelCase") { words($0).enumerated().map { $0 == 0 ? $1.lowercased() : $1.capitalized }.joined() },
            Transform(title: "snake_case") { words($0).map { $0.lowercased() }.joined(separator: "_") },
            Transform(title: "kebab-case") { words($0).map { $0.lowercased() }.joined(separator: "-") },
        ],
        [
            Transform(title: "Trim Whitespace") { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            Transform(title: "Join Lines") {
                $0.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }.joined(separator: " ")
            },
            Transform(title: "Sort Lines") { lines($0).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: "\n") },
            Transform(title: "Remove Duplicate Lines") {
                var seen = Set<String>()
                return lines($0).filter { seen.insert($0).inserted }.joined(separator: "\n")
            },
        ],
        [
            Transform(title: "Format JSON") { json($0, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) },
            Transform(title: "Minify JSON") { json($0, options: [.withoutEscapingSlashes]) },
            Transform(title: "URL Encode") { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) },
            Transform(title: "URL Decode") { $0.removingPercentEncoding },
            Transform(title: "Base64 Encode") { Data($0.utf8).base64EncodedString() },
            Transform(title: "Base64 Decode") { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let padded = trimmed + String(repeating: "=", count: (4 - trimmed.count % 4) % 4)
                return Data(base64Encoded: padded).flatMap { String(data: $0, encoding: .utf8) }
            },
        ],
    ]

    /// "fooBar baz-qux HTTPServer" → ["foo", "Bar", "baz", "qux", "HTTP", "Server"].
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            // A new word starts at a lower→upper step, or at the last capital of an acronym ("HTTPServer").
            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if character.isUppercase, !current.isEmpty,
               previous?.isLowercase == true || (previous?.isUppercase == true && next?.isLowercase == true) {
                words.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func json(_ text: String, options: JSONSerialization.WritingOptions) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]),
              let data = try? JSONSerialization.data(withJSONObject: object, options: options.union(.fragmentsAllowed))
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension CharacterSet {
    /// Unreserved characters only, so the result is safe in any part of a URL.
    static let urlQueryValueAllowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
