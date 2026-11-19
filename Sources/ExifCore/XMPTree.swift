import Foundation

/// Minimale, standardkonforme Darstellung von XMP-Werten (RDF/XML), um verschachtelte
/// Strukturen wie Bildregionen lesen und schreiben zu können.
///
/// ImageIO kann solche Strukturen zwar speichern, bietet aber keine bequeme API, um sie
/// aufzubauen. Daher erzeugen wir das XMP selbst, lassen es von ImageIO parsen und übernehmen
/// die fertigen Einträge in die Bild-Metadaten.
public enum XMPArrayKind: String, Sendable {
    case bag = "Bag"
    case seq = "Seq"
    case alt = "Alt"
}

public struct XMPItem: Equatable, Sendable {
    public var lang: String?
    public var value: XMPNode

    public init(lang: String? = nil, value: XMPNode) {
        self.lang = lang
        self.value = value
    }
}

public struct XMPField: Equatable, Sendable {
    public var namespace: String
    public var name: String
    public var value: XMPNode

    public init(_ namespace: String, _ name: String, _ value: XMPNode) {
        self.namespace = namespace
        self.name = name
        self.value = value
    }
}

public indirect enum XMPNode: Equatable, Sendable {
    case text(String)
    case structure([XMPField])
    case array(XMPArrayKind, [XMPItem])

    /// Text eines einfachen Werts bzw. des ersten Eintrags einer Liste (z. B. „x-default“).
    public var stringValue: String? {
        switch self {
        case .text(let s): return s
        case .array(_, let items): return items.first?.value.stringValue
        case .structure: return nil
        }
    }

    public var doubleValue: Double? {
        stringValue.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    public var fields: [XMPField] {
        if case .structure(let f) = self { return f }
        return []
    }

    public var items: [XMPItem] {
        if case .array(_, let i) = self { return i }
        return []
    }

    public var strings: [String] {
        switch self {
        case .text(let s): return [s]
        case .array(_, let items): return items.compactMap(\.value.stringValue)
        case .structure: return []
        }
    }

    public func field(_ namespace: String, _ name: String) -> XMPNode? {
        fields.first { $0.namespace == namespace && $0.name == name }?.value
    }
}

public enum XMP {
    public static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let xmlNamespace = "http://www.w3.org/XML/1998/namespace"

    /// Übliche Präfixe; unbekannte Namensräume bekommen automatisch eines.
    static let knownPrefixes: [String: String] = [
        "http://www.metadataworkinggroup.com/schemas/regions/": "mwg-rs",
        "http://ns.adobe.com/xmp/sType/Area#": "stArea",
        "http://ns.adobe.com/xap/1.0/sType/Dimensions#": "stDim",
        "http://iptc.org/std/Iptc4xmpExt/2008-02-29/": "Iptc4xmpExt",
        "http://purl.org/dc/elements/1.1/": "dc",
    ]

    // MARK: - Lesen

    /// Alle Eigenschaften der obersten Ebene eines XMP-Pakets.
    public static func parse(_ data: Data) -> [XMPField] {
        guard let doc = try? XMLDocument(data: data, options: []), let root = doc.rootElement() else { return [] }
        var result: [XMPField] = []
        collectDescriptions(root, into: &result)
        return result
    }

    private static func collectDescriptions(_ element: XMLElement, into result: inout [XMPField]) {
        if element.uri == rdf && element.localName == "Description" {
            result += properties(of: element)
            return
        }
        for case let child as XMLElement in element.children ?? [] {
            collectDescriptions(child, into: &result)
        }
    }

    private static func namespace(of node: XMLNode, in element: XMLElement) -> String? {
        if let uri = node.uri, !uri.isEmpty { return uri }
        guard let name = node.name, let colon = name.firstIndex(of: ":") else { return nil }
        let prefix = String(name[..<colon])
        if prefix == "xml" { return xmlNamespace }
        return element.resolveNamespace(forName: name)?.stringValue
            ?? element.namespace(forPrefix: prefix)?.stringValue
    }

    private static func properties(of element: XMLElement) -> [XMPField] {
        var fields: [XMPField] = []
        for attribute in element.attributes ?? [] {
            guard let name = attribute.name, !name.hasPrefix("xmlns"),
                  let ns = namespace(of: attribute, in: element),
                  ns != rdf, ns != xmlNamespace else { continue }
            let local = attribute.localName ?? name
            fields.append(XMPField(ns, local, .text(attribute.stringValue ?? "")))
        }
        for case let child as XMLElement in element.children ?? [] {
            guard let ns = namespace(of: child, in: child), let local = child.localName else { continue }
            fields.append(XMPField(ns, local, value(of: child)))
        }
        return fields
    }

    private static func isRDF(_ element: XMLElement, _ local: String) -> Bool {
        element.localName == local && (element.uri == rdf || element.name == "rdf:\(local)")
    }

    private static func rdfAttribute(_ element: XMLElement, _ local: String) -> String? {
        (element.attribute(forLocalName: local, uri: rdf) ?? element.attribute(forName: "rdf:\(local)"))?.stringValue
    }

    private static func value(of element: XMLElement) -> XMPNode {
        if let resource = rdfAttribute(element, "resource") { return .text(resource) }
        let children = (element.children ?? []).compactMap { $0 as? XMLElement }

        if let container = children.first(where: { isRDF($0, "Bag") || isRDF($0, "Seq") || isRDF($0, "Alt") }) {
            let kind = XMPArrayKind(rawValue: container.localName ?? "Bag") ?? .bag
            let items = (container.children ?? [])
                .compactMap { $0 as? XMLElement }
                .filter { isRDF($0, "li") }
                .map { li in
                    XMPItem(lang: (li.attribute(forLocalName: "lang", uri: xmlNamespace)
                                   ?? li.attribute(forName: "xml:lang"))?.stringValue,
                            value: value(of: li))
                }
            return .array(kind, items)
        }
        if rdfAttribute(element, "parseType") == "Resource" {
            return .structure(properties(of: element))
        }
        if let description = children.first(where: { isRDF($0, "Description") }) {
            return .structure(properties(of: description))
        }
        let props = properties(of: element)
        if !props.isEmpty { return .structure(props) }
        return .text(element.stringValue ?? "")
    }

    // MARK: - Schreiben

    /// Erzeugt ein vollständiges XMP-Paket und liefert die verwendeten Präfixe mit.
    public static func serialize(_ fields: [XMPField]) -> (data: Data, prefixes: [String: String]) {
        var prefixes: [String: String] = [:]
        var counter = 0
        func register(_ ns: String) {
            guard prefixes[ns] == nil else { return }
            if let known = knownPrefixes[ns] {
                prefixes[ns] = known
            } else {
                counter += 1
                prefixes[ns] = "ns\(counter)"
            }
        }
        func collect(_ node: XMPNode) {
            switch node {
            case .text: break
            case .structure(let f): f.forEach { register($0.namespace); collect($0.value) }
            case .array(_, let items): items.forEach { collect($0.value) }
            }
        }
        fields.forEach { register($0.namespace); collect($0.value) }

        let declarations = prefixes
            .sorted { $0.value < $1.value }
            .map { " xmlns:\($0.value)=\"\(escape($0.key))\"" }
            .joined()
        let body = fields.map { xml(for: $0, prefixes) }.joined()
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="\(rdf)">\
        <rdf:Description rdf:about=""\(declarations)>\(body)</rdf:Description>\
        </rdf:RDF></x:xmpmeta>
        """
        return (Data(xml.utf8), prefixes)
    }

    private static func xml(for field: XMPField, _ prefixes: [String: String]) -> String {
        let q = "\(prefixes[field.namespace] ?? "ns"):\(field.name)"
        switch field.value {
        case .text(let s):
            return "<\(q)>\(escape(s))</\(q)>"
        case .structure(let f):
            return "<\(q) rdf:parseType=\"Resource\">\(f.map { xml(for: $0, prefixes) }.joined())</\(q)>"
        case .array(let kind, let items):
            return "<\(q)><rdf:\(kind.rawValue)>\(items.map { xml(for: $0, prefixes) }.joined())</rdf:\(kind.rawValue)></\(q)>"
        }
    }

    private static func xml(for item: XMPItem, _ prefixes: [String: String]) -> String {
        let lang = item.lang.map { " xml:lang=\"\(escape($0))\"" } ?? ""
        switch item.value {
        case .text(let s):
            return "<rdf:li\(lang)>\(escape(s))</rdf:li>"
        case .structure(let f):
            return "<rdf:li\(lang) rdf:parseType=\"Resource\">\(f.map { xml(for: $0, prefixes) }.joined())</rdf:li>"
        case .array(let kind, let items):
            return "<rdf:li\(lang)><rdf:\(kind.rawValue)>\(items.map { xml(for: $0, prefixes) }.joined())</rdf:\(kind.rawValue)></rdf:li>"
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
