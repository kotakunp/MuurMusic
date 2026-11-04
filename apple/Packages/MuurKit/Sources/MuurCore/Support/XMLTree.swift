import Foundation

/// A lightweight XML element tree (namespace prefixes stripped). Named `XNode` to avoid
/// clashing with Foundation's `XMLNode`/`XMLElement` on macOS.
public final class XNode: @unchecked Sendable {
    public let name: String
    public var attributes: [String: String]
    public var children: [XNode] = []
    public var text: String = ""
    public weak var parent: XNode?

    public init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }

    /// First direct child with the given local name (case-insensitive).
    public func child(_ name: String) -> XNode? {
        children.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func children(_ name: String) -> [XNode] {
        children.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Text content of the first direct child named `name`, trimmed.
    public func childText(_ name: String) -> String? {
        guard let node = child(name) else { return nil }
        let value = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// All descendants (depth-first) with the given local name.
    public func descendants(_ name: String) -> [XNode] {
        var result: [XNode] = []
        for child in children {
            if child.name.caseInsensitiveCompare(name) == .orderedSame { result.append(child) }
            result.append(contentsOf: child.descendants(name))
        }
        return result
    }

    public func firstDescendant(_ name: String) -> XNode? {
        for child in children {
            if child.name.caseInsensitiveCompare(name) == .orderedSame { return child }
            if let found = child.firstDescendant(name) { return found }
        }
        return nil
    }

    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum XMLTree {
    public static func parse(_ data: Data) throws -> XNode {
        let delegate = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            let message = parser.parserError?.localizedDescription ?? "Malformed XML"
            throw MuurError.invalidData(message)
        }
        return root
    }

    public static func parse(_ string: String) throws -> XNode {
        try parse(Data(string.utf8))
    }

    /// Escapes text for inclusion in XML.
    public static func escape(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for character in string {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: XNode?
        private var stack: [XNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            var local = elementName
            if let colon = local.lastIndex(of: ":") { local = String(local[local.index(after: colon)...]) }
            var attributes: [String: String] = [:]
            for (key, value) in attributeDict {
                var name = key
                if let colon = name.lastIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
                attributes[name] = value
            }
            let node = XNode(name: local, attributes: attributes)
            if let parent = stack.last {
                node.parent = parent
                parent.children.append(node)
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let string = String(data: CDATABlock, encoding: .utf8) {
                stack.last?.text += string
            }
        }
    }
}
