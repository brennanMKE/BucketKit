import Foundation

/// Internal Codable bridge for the fixed S3 XML schemas in
/// ``ResponseModels.swift``.
///
/// This is deliberately not a general-purpose XML decoder. It only
/// implements what the package's response models need: PascalCase
/// element names mapping 1:1 to coding keys, scalar leaf text
/// (`String`, `Int`, `Int64`, `Bool`, `Date`), and repeated child
/// elements decoding as `Array`.
enum XMLDecoder {
    /// Parse `data` and decode it into `type`.
    ///
    /// Errors thrown out of this function are always
    /// ``XMLDecodingError`` — Foundation's `XMLParser` errors and
    /// `DecodingError`s are translated at the boundary so callers
    /// only have to handle one type.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let root = try SAXReader.parse(data)
        let decoder = _XMLNodeDecoder(node: root, codingPath: [])
        do {
            return try T(from: decoder)
        } catch let error as XMLDecodingError {
            throw error
        } catch let error as DecodingError {
            throw XMLDecodingError.schema(String(describing: error))
        }
    }
}

/// ISO 8601 / RFC 3339 date parsing for S3 timestamps.
///
/// `ISO8601DateFormatter` is a Foundation reference type that
/// `Sendable`-checks reject as a global, so we construct fresh
/// formatters per call. The cost (~µs) is negligible compared to
/// the rest of decoding and avoids sharing mutable state across
/// isolation domains. We accept both fractional-second
/// (`2024-01-02T03:04:05.000Z`) and integer-second variants S3
/// providers emit.
private enum ISO8601 {
    static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }
}

// MARK: - Tree helpers

private extension XMLNode {
    var elementName: String? {
        if case .element(let name, _, _) = self { return name }
        return nil
    }

    /// Concatenated, trimmed text of this node. For an element this
    /// is the joined text of its direct text children; element
    /// children are skipped (leaf-text decoding only).
    var leafText: String {
        switch self {
        case .text(let s):
            return s
        case .element(_, _, let children):
            var buf = ""
            for child in children {
                if case .text(let s) = child {
                    buf += s
                }
            }
            return buf.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Direct child elements (text nodes filtered out).
    var childElements: [XMLNode] {
        guard case .element(_, _, let children) = self else { return [] }
        return children.filter { $0.elementName != nil }
    }
}

// MARK: - Decoder

/// `Decoder` over a single ``XMLNode``.
///
/// The decoder is recursive: `container(keyedBy:)` returns a keyed
/// container backed by this node's children, `unkeyedContainer()`
/// is used for the array-element case and walks siblings of a given
/// name in the parent (handled by the keyed container), and
/// `singleValueContainer()` decodes the leaf text.
private struct _XMLNodeDecoder: Decoder {
    let node: XMLNode
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(_KeyedContainer<Key>(node: node, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        // Unkeyed-at-root is not used by our schemas; arrays are
        // always nested under a parent element.
        throw XMLDecodingError.schema("unkeyed container at root is not supported")
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        _SingleValueContainer(node: node, codingPath: codingPath)
    }
}

// MARK: - Keyed container

private struct _KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let node: XMLNode
    let codingPath: [CodingKey]

    var allKeys: [Key] {
        node.childElements.compactMap { child in
            child.elementName.flatMap { Key(stringValue: $0) }
        }
    }

    private func children(named name: String) -> [XMLNode] {
        node.childElements.filter { $0.elementName == name }
    }

    private func firstChild(named name: String) -> XMLNode? {
        node.childElements.first { $0.elementName == name }
    }

    func contains(_ key: Key) -> Bool {
        firstChild(named: key.stringValue) != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        // S3 omits absent fields rather than emitting empty
        // elements. Treat "no child element" as nil.
        firstChild(named: key.stringValue) == nil
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        let text = try leafText(forKey: key)
        switch text.lowercased() {
        case "true": return true
        case "false": return false
        default:
            throw XMLDecodingError.typeMismatch(expected: "Bool", actual: text)
        }
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try leafText(forKey: key)
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        let text = try leafText(forKey: key)
        guard let v = Double(text) else {
            throw XMLDecodingError.typeMismatch(expected: "Double", actual: text)
        }
        return v
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        let text = try leafText(forKey: key)
        guard let v = Float(text) else {
            throw XMLDecodingError.typeMismatch(expected: "Float", actual: text)
        }
        return v
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        let text = try leafText(forKey: key)
        guard let v = Int(text) else {
            throw XMLDecodingError.typeMismatch(expected: "Int", actual: text)
        }
        return v
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try decodeFixedWidth(forKey: key) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try decodeFixedWidth(forKey: key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try decodeFixedWidth(forKey: key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try decodeFixedWidth(forKey: key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try decodeFixedWidth(forKey: key) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try decodeFixedWidth(forKey: key) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try decodeFixedWidth(forKey: key) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try decodeFixedWidth(forKey: key) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try decodeFixedWidth(forKey: key) }

    private func decodeFixedWidth<T: FixedWidthInteger>(forKey key: Key) throws -> T {
        let text = try leafText(forKey: key)
        guard let v = T(text) else {
            throw XMLDecodingError.typeMismatch(expected: String(describing: T.self), actual: text)
        }
        return v
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        // Date is handled here because Foundation's default Date
        // decoding goes via singleValueContainer/Double — we want
        // ISO8601 leaf text instead.
        if type == Date.self {
            let text = try leafText(forKey: key)
            guard let date = ISO8601.parse(text) else {
                throw XMLDecodingError.typeMismatch(expected: "ISO8601 Date", actual: text)
            }
            return date as! T
        }

        // Arrays: collect all sibling elements with the matching
        // name and decode each as `Element`.
        if let arrayType = type as? any _XMLArrayDecodable.Type {
            let elements = children(named: key.stringValue)
            let decoded = try arrayType._decodeXMLElements(
                elements,
                codingPath: codingPath + [key]
            )
            return decoded as! T
        }

        guard let child = firstChild(named: key.stringValue) else {
            throw XMLDecodingError.schema("missing element \(key.stringValue) in \(node.elementName ?? "<root>")")
        }
        let decoder = _XMLNodeDecoder(node: child, codingPath: codingPath + [key])
        return try T(from: decoder)
    }

    private func leafText(forKey key: Key) throws -> String {
        guard let child = firstChild(named: key.stringValue) else {
            throw XMLDecodingError.schema("missing element \(key.stringValue) in \(node.elementName ?? "<root>")")
        }
        return child.leafText
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        guard let child = firstChild(named: key.stringValue) else {
            throw XMLDecodingError.schema("missing element \(key.stringValue) in \(node.elementName ?? "<root>")")
        }
        return KeyedDecodingContainer(_KeyedContainer<NestedKey>(node: child, codingPath: codingPath + [key]))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        let elements = children(named: key.stringValue)
        return _UnkeyedContainer(elements: elements, codingPath: codingPath + [key])
    }

    func superDecoder() throws -> Decoder {
        _XMLNodeDecoder(node: node, codingPath: codingPath)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        guard let child = firstChild(named: key.stringValue) else {
            throw XMLDecodingError.schema("missing element \(key.stringValue) in \(node.elementName ?? "<root>")")
        }
        return _XMLNodeDecoder(node: child, codingPath: codingPath + [key])
    }
}

// MARK: - Unkeyed container

/// Used for `nestedUnkeyedContainer(forKey:)`. The package's models
/// prefer typed `[T]` properties (handled via `_XMLArrayDecodable`),
/// so this exists for completeness rather than active use.
private struct _UnkeyedContainer: UnkeyedDecodingContainer {
    let elements: [XMLNode]
    let codingPath: [CodingKey]
    var currentIndex: Int = 0

    var count: Int? { elements.count }
    var isAtEnd: Bool { currentIndex >= elements.count }

    mutating func decodeNil() throws -> Bool { false }

    private mutating func nextDecoder() throws -> _XMLNodeDecoder {
        guard !isAtEnd else {
            throw XMLDecodingError.schema("unkeyed container exhausted")
        }
        let node = elements[currentIndex]
        currentIndex += 1
        return _XMLNodeDecoder(node: node, codingPath: codingPath)
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try T(from: try nextDecoder())
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let decoder = try nextDecoder()
        return try decoder.container(keyedBy: NestedKey.self)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw XMLDecodingError.schema("nested unkeyed containers are not supported")
    }

    mutating func superDecoder() throws -> Decoder {
        try nextDecoder()
    }
}

// MARK: - Single-value container

private struct _SingleValueContainer: SingleValueDecodingContainer {
    let node: XMLNode
    let codingPath: [CodingKey]

    func decodeNil() -> Bool {
        node.leafText.isEmpty
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        switch node.leafText.lowercased() {
        case "true": return true
        case "false": return false
        default: throw XMLDecodingError.typeMismatch(expected: "Bool", actual: node.leafText)
        }
    }

    func decode(_ type: String.Type) throws -> String { node.leafText }

    func decode(_ type: Double.Type) throws -> Double {
        guard let v = Double(node.leafText) else {
            throw XMLDecodingError.typeMismatch(expected: "Double", actual: node.leafText)
        }
        return v
    }

    func decode(_ type: Float.Type) throws -> Float {
        guard let v = Float(node.leafText) else {
            throw XMLDecodingError.typeMismatch(expected: "Float", actual: node.leafText)
        }
        return v
    }

    private func decodeFixedWidth<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        guard let v = T(node.leafText) else {
            throw XMLDecodingError.typeMismatch(expected: String(describing: T.self), actual: node.leafText)
        }
        return v
    }

    func decode(_ type: Int.Type) throws -> Int { try decodeFixedWidth(Int.self) }
    func decode(_ type: Int8.Type) throws -> Int8 { try decodeFixedWidth(Int8.self) }
    func decode(_ type: Int16.Type) throws -> Int16 { try decodeFixedWidth(Int16.self) }
    func decode(_ type: Int32.Type) throws -> Int32 { try decodeFixedWidth(Int32.self) }
    func decode(_ type: Int64.Type) throws -> Int64 { try decodeFixedWidth(Int64.self) }
    func decode(_ type: UInt.Type) throws -> UInt { try decodeFixedWidth(UInt.self) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try decodeFixedWidth(UInt8.self) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try decodeFixedWidth(UInt16.self) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try decodeFixedWidth(UInt32.self) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try decodeFixedWidth(UInt64.self) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if type == Date.self {
            guard let date = ISO8601.parse(node.leafText) else {
                throw XMLDecodingError.typeMismatch(expected: "ISO8601 Date", actual: node.leafText)
            }
            return date as! T
        }
        let decoder = _XMLNodeDecoder(node: node, codingPath: codingPath)
        return try T(from: decoder)
    }
}

// MARK: - Array decoding hook

/// Hook so the keyed container can recognise arrays at runtime
/// (`type is Array<X>.Type` is awkward without conditional casts).
/// Conformance is added in an extension below.
private protocol _XMLArrayDecodable {
    static func _decodeXMLElements(_ elements: [XMLNode], codingPath: [CodingKey]) throws -> Any
}

extension Array: _XMLArrayDecodable where Element: Decodable {
    static func _decodeXMLElements(_ elements: [XMLNode], codingPath: [CodingKey]) throws -> Any {
        var out: [Element] = []
        out.reserveCapacity(elements.count)
        for node in elements {
            let decoder = _XMLNodeDecoder(node: node, codingPath: codingPath)
            out.append(try Element(from: decoder))
        }
        return out
    }
}
