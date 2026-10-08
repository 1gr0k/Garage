import Foundation

extension ServiceType {
    /// Ключ сопоставления записи и правила. Для фиксированных типов — `storageString`; для `.other` —
    /// текст с обрезанными краями, схлопнутыми внутренними пробельными символами в один пробел и
    /// `lowercased()` (не зависит от локали, есть на Linux). Диакритика не сворачивается: «ё» и «е»,
    /// «й» и «и» — разные буквы.
    ///
    /// Префикс `other:` оставляет `.other("oilChange")` и `.oilChange` разными ключами.
    public var matchKey: String {
        switch self {
        case .other(let text):
            "other:" + text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        default:
            storageString
        }
    }
}
