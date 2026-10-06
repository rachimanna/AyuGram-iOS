import Foundation

/// Word/grapheme-safe difference; bounded to avoid quadratic work for very long text.
enum TextDiff {
    enum Kind: Equatable { case same, inserted, removed }
    struct Run { var text: String; var kind: Kind }
    static func runs(old: String, new: String) -> [Run] {
        if old == new { return [Run(text: new, kind: .same)] }
        guard old.count + new.count <= 8_000 else { return [Run(text: old, kind: .removed), Run(text: "\n" + new, kind: .inserted)] }
        let a = Array(old), b = Array(new)
        let difference = b.difference(from: a)
        var removals: Set<Int> = [], insertions: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }
        var result: [Run] = []
        func append(_ character: Character, kind: Kind) {
            if result.last?.kind == kind { result[result.count - 1].text.append(character) }
            else { result.append(Run(text: String(character), kind: kind)) }
        }
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count && removals.contains(i) { append(a[i], kind: .removed); i += 1 }
            else if j < b.count && insertions.contains(j) { append(b[j], kind: .inserted); j += 1 }
            else if j < b.count { append(b[j], kind: .same); i += 1; j += 1 }
            else { break }
        }
        return result
    }
}
