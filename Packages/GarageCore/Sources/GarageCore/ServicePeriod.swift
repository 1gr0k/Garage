import Foundation

/// Интервал обслуживания по времени. Месяцы — отдельно от дней: «12 месяцев» не равно «365 дней»
/// (високосный год, конец месяца).
///
/// Кодируется одной строкой: `"days:30"`, `"months:12"`. Формат сохраняется и уходит на сервер,
/// поэтому названия не переименовываем.
public enum ServicePeriod: Hashable, Sendable {
    case days(Int)
    case months(Int)

    public static let daysRange = 1...3650
    public static let monthsRange = 1...120

    /// Число дней или месяцев, как его вводит пользователь.
    public var value: Int {
        switch self {
        case .days(let value), .months(let value): value
        }
    }

    /// Проверяет границы; тот же инвариант, что у `MaintenanceRule.init`.
    func validate() throws(ValidationError) {
        switch self {
        case .days(let value):
            guard Self.daysRange.contains(value) else { throw .periodOutOfRange(value) }
        case .months(let value):
            guard Self.monthsRange.contains(value) else { throw .periodOutOfRange(value) }
        }
    }
}

extension ServicePeriod {
    private static let daysPrefix = "days:"
    private static let monthsPrefix = "months:"

    /// Число в каноничной записи: `"+5"` и `"007"` не принимаем, иначе незнакомая строка вернулась бы на сервер
    /// изменённой (`"days:5"`), а не сырой.
    private static func canonicalInt(_ digits: Substring) -> Int? {
        guard let value = Int(digits), String(value) == digits else { return nil }
        return value
    }

    public var storageString: String {
        switch self {
        case .days(let value): Self.daysPrefix + String(value)
        case .months(let value): Self.monthsPrefix + String(value)
        }
    }

    /// Разбирает `storageString` и проверяет границы.
    /// - Throws: `ValidationError.unknownPeriod` на незнакомый формат (например `"weeks:2"`),
    ///   `periodOutOfRange` на значение вне границ.
    public init(storageString string: String) throws(ValidationError) {
        if string.hasPrefix(Self.daysPrefix), let value = Self.canonicalInt(string.dropFirst(Self.daysPrefix.count)) {
            self = .days(value)
        } else if string.hasPrefix(Self.monthsPrefix),
            let value = Self.canonicalInt(string.dropFirst(Self.monthsPrefix.count))
        {
            self = .months(value)
        } else {
            throw .unknownPeriod(string)
        }
        try validate()
    }
}

extension ServicePeriod: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        do {
            try self.init(storageString: string)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid period \"\(string)\"")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageString)
    }
}
