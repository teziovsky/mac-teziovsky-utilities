import Foundation
import ImageIO

/// Parses and formats EXIF/TIFF timestamps (`yyyy:MM:dd HH:mm:ss`) together with their
/// optional EXIF 2.31 offset (`±HH:MM`).
///
/// A timestamp without an offset is interpreted in the current time zone, which matches how
/// cameras without offset support record local wall-clock time. When an offset is present it
/// always wins, so photos taken in another time zone keep their real moment and local time.
/// Pure value logic (no `DateFormatter`), so it is cheap and safe to call concurrently.
enum ExifDateCodec {
    /// EXIF date fields paired with the offset field that qualifies them.
    struct Field {
        let dictionary: CFString
        let dateKey: CFString
        let offsetKey: CFString
        let source: FileDateSource

        static let original = Field(
            dictionary: kCGImagePropertyExifDictionary,
            dateKey: kCGImagePropertyExifDateTimeOriginal,
            offsetKey: kCGImagePropertyExifOffsetTimeOriginal,
            source: .exifOriginal
        )
        static let digitized = Field(
            dictionary: kCGImagePropertyExifDictionary,
            dateKey: kCGImagePropertyExifDateTimeDigitized,
            offsetKey: kCGImagePropertyExifOffsetTimeDigitized,
            source: .exifDigitized
        )
        /// TIFF `DateTime` is qualified by EXIF `OffsetTime`.
        static let tiff = Field(
            dictionary: kCGImagePropertyTIFFDictionary,
            dateKey: kCGImagePropertyTIFFDateTime,
            offsetKey: kCGImagePropertyExifOffsetTime,
            source: .tiffDateTime
        )

        static let all: [Field] = [.original, .digitized, .tiff]
    }

    static func date(from value: String, offset: String? = nil) -> Date? {
        let numbers = value
            .split(whereSeparator: { !$0.isNumber })
            .prefix(6)
            .map(String.init)
        guard numbers.count == 6,
              numbers[0].count == 4,
              numbers.dropFirst().allSatisfy({ $0.count == 2 }) else {
            return nil
        }
        let values = numbers.compactMap(Int.init)
        guard values.count == 6 else { return nil }

        let calendar = calendar(in: timeZone(forOffset: offset) ?? .current)
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: values[0],
            month: values[1],
            day: values[2],
            hour: values[3],
            minute: values[4],
            second: values[5]
        )
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    /// EXIF representation: `yyyy:MM:dd HH:mm:ss` as local time in `offset` (or the current zone).
    static func string(from date: Date, offset: String? = nil) -> String {
        format(date, offset: offset, pattern: "%04d:%02d:%02d %02d:%02d:%02d")
    }

    /// XMP representation of the same local time (`yyyy-MM-ddTHH:mm:ss`). ImageIO's metadata
    /// model stores EXIF dates as XMP tags, and only this form updates every EXIF/TIFF date
    /// field consistently across JPEG, HEIC and TIFF when the container is copied.
    static func xmpString(from date: Date, offset: String? = nil) -> String {
        format(date, offset: offset, pattern: "%04d-%02d-%02dT%02d:%02d:%02d")
    }

    private static func format(_ date: Date, offset: String?, pattern: String) -> String {
        let calendar = calendar(in: timeZone(forOffset: offset) ?? .current)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: pattern,
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }

    /// Parses `+09:00`, `-05:30`, `+0100` or `Z`. Returns nil for blank or malformed offsets.
    static func timeZone(forOffset offset: String?) -> TimeZone? {
        guard let trimmed = offset?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        if trimmed == "Z" { return TimeZone(secondsFromGMT: 0) }
        guard let sign = trimmed.first, sign == "+" || sign == "-" else { return nil }
        let digits = trimmed.dropFirst().filter(\.isNumber)
        guard digits.count == 4,
              let hours = Int(digits.prefix(2)),
              let minutes = Int(digits.suffix(2)),
              hours <= 14, minutes < 60 else {
            return nil
        }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    /// Reads the date stored in `field`, honouring its offset when present.
    static func date(for field: Field, in properties: [CFString: Any]) -> Date? {
        guard let dictionary = properties[field.dictionary] as? [CFString: Any],
              let value = dictionary[field.dateKey] as? String else {
            return nil
        }
        return date(from: value, offset: offset(for: field, in: properties))
    }

    static func offset(for field: Field, in properties: [CFString: Any]) -> String? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        return exif?[field.offsetKey] as? String
    }

    private static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
