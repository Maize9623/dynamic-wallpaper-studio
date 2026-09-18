import Foundation

enum TextEncodingDetector {
    static func readAllText(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if looksLikeUTF8(data), let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: gb18030) {
            return text
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    private static func looksLikeUTF8(_ data: Data) -> Bool {
        var index = 0
        let bytes = [UInt8](data)
        while index < bytes.count {
            let byte = bytes[index]
            let remaining: Int
            if byte <= 0x7F {
                remaining = 0
            } else if byte >= 0xC2 && byte <= 0xDF {
                remaining = 1
            } else if byte >= 0xE0 && byte <= 0xEF {
                remaining = 2
            } else if byte >= 0xF0 && byte <= 0xF4 {
                remaining = 3
            } else {
                return false
            }
            if remaining == 0 {
                index += 1
                continue
            }
            guard index + remaining < bytes.count else { return false }
            for offset in 1...remaining {
                if bytes[index + offset] & 0xC0 != 0x80 { return false }
            }
            index += remaining + 1
        }
        return true
    }

    private static var gb18030: String.Encoding {
        let cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}
