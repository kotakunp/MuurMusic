import Foundation

/// Detects audio container formats from file signatures. Used to give downloaded media-server files
/// (whose URIs carry no extension) a file extension the decoders recognize.
public enum AudioFormatSniffer {
    /// The lowercase file extension matching the content of `url`, or nil when the format is unknown.
    public static func fileExtension(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 64)) ?? Data()
        return fileExtension(header: header)
    }

    /// The lowercase file extension for the first bytes of a file (at least 12 bytes are needed for most formats).
    public static func fileExtension(header data: Data) -> String? {
        let bytes = [UInt8](data.prefix(64))
        guard bytes.count >= 4 else { return nil }
        func ascii(_ offset: Int, _ length: Int) -> String {
            guard bytes.count >= offset + length else { return "" }
            return String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
        }
        switch ascii(0, 4) {
        case "fLaC": return "flac"
        case "OggS":
            let page = String(decoding: bytes, as: UTF8.self)
            if page.contains("OpusHead") { return "opus" }
            if page.contains("Speex") { return "spx" }
            if page.contains("FLAC") { return "oga" }
            return "ogg"
        case "RIFF":
            return ascii(8, 4) == "WAVE" ? "wav" : nil
        case "RF64": return "rf64"
        case "FORM":
            let type = ascii(8, 4)
            return type == "AIFF" ? "aiff" : (type == "AIFC" ? "aifc" : nil)
        case "FRM8": return "dff"
        case "DSD ": return "dsf"
        case "MAC ": return "ape"
        case "wvpk": return "wv"
        case "caff": return "caf"
        case "TTA1": return "tta"
        case "MPCK": return "mpc"
        case "ajkg": return "shn"
        case ".snd": return "au"
        default: break
        }
        if ascii(0, 3) == "MP+" { return "mpc" }
        if ascii(4, 4) == "ftyp" {
            let brand = ascii(8, 4)
            if brand.hasPrefix("3gp") || brand.hasPrefix("3g2") { return "3gp" }
            if brand == "M4B " { return "m4b" }
            return "m4a"
        }
        if ascii(0, 3) == "ID3" { return "mp3" }
        if bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3 { return "mka" }
        if bytes[0] == 0x0B && bytes[1] == 0x77 { return "ac3" }
        if bytes[0] == 0xFF && (bytes[1] & 0xF6) == 0xF0 { return "aac" }
        if bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0 { return "mp3" }
        if ascii(0, 6) == "#!AMR\n" { return "amr" }
        return nil
    }
}
