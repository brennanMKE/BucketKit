import Foundation

/// Lightweight node tree parsed from an XML document.
///
/// The XML decoding pipeline parses an S3 response into a small tree
/// of these values via ``SAXReader/parse(_:)``, then walks the tree
/// with ``XMLDecoder``. We do not expose this representation
/// publicly; it exists only as the bridge between Foundation's
/// `XMLParser` and our `Decoder` implementation.
enum XMLNode: Sendable {
    /// An element with an optional set of attributes and ordered
    /// children. Children may be other elements or text fragments.
    case element(name: String, attributes: [String: String], children: [XMLNode])

    /// A run of character data inside an element.
    case text(String)
}

/// Errors produced while parsing or decoding an XML document.
///
/// Kept as a single enum so the SAX layer never leaks Foundation's
/// `XMLParser.ErrorCode` past its boundary. The public client
/// surface (#0015) translates these to ``BucketClientError``.
enum XMLDecodingError: Error, Sendable {
    /// The underlying `XMLParser` reported a syntax error.
    case parse(String)

    /// The document parsed but the element layout did not match the
    /// schema we were decoding into (missing required field, wrong
    /// container shape, etc.).
    case schema(String)

    /// A leaf element's text could not be coerced to the requested
    /// scalar type.
    case typeMismatch(expected: String, actual: String)
}

/// Internal SAX-style XML reader built on `Foundation.XMLParser`.
///
/// The reader runs synchronously — `XMLParser` is itself
/// synchronous — and produces an ``XMLNode`` tree from a `Data`
/// blob. It is `final` and `Sendable`; the parser delegate it
/// installs is internal and not exposed.
///
/// We chose parse-to-tree over a streaming `Decoder` because the
/// package only needs to decode a handful of fixed schemas, the
/// largest of which (a paginated `ListObjectsV2` page) is bounded
/// by `MaxKeys`. A small tree keeps the decoder logic
/// straightforward.
final class SAXReader: Sendable {
    /// Parse a UTF-8 XML payload into a single root ``XMLNode``.
    ///
    /// The S3 wire format always has exactly one document element;
    /// this returns that element. Whitespace-only text between
    /// elements is preserved in the tree but ignored by leaf-text
    /// decoding (which trims).
    static func parse(_ data: Data) throws -> XMLNode {
        let delegate = TreeBuildingDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            if let error = delegate.parseError {
                throw error
            }
            if let parserError = parser.parserError {
                throw XMLDecodingError.parse(parserError.localizedDescription)
            }
            throw XMLDecodingError.parse("unknown XML parse failure")
        }

        guard let root = delegate.root else {
            throw XMLDecodingError.parse("document had no root element")
        }
        return root
    }
}

/// `XMLParser` delegate that builds an ``XMLNode`` tree.
///
/// Not `Sendable`: it is constructed and used on a single call to
/// `XMLParser.parse()`, which is synchronous, so no isolation is
/// required. We intentionally keep it `private` to the reader.
private final class TreeBuildingDelegate: NSObject, XMLParserDelegate {
    /// Frame we mutate while a given element is open. Children are
    /// appended in document order; text is appended as ``XMLNode/text``.
    private struct Frame {
        let name: String
        let attributes: [String: String]
        var children: [XMLNode]
    }

    private var stack: [Frame] = []
    var root: XMLNode?
    var parseError: XMLDecodingError?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        stack.append(Frame(name: elementName, attributes: attributeDict, children: []))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        // Coalesce consecutive text into a single text node.
        if case .text(let existing) = stack[stack.count - 1].children.last {
            stack[stack.count - 1].children.removeLast()
            stack[stack.count - 1].children.append(.text(existing + string))
        } else {
            stack[stack.count - 1].children.append(.text(string))
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        guard let frame = stack.popLast() else { return }
        let node = XMLNode.element(
            name: frame.name,
            attributes: frame.attributes,
            children: frame.children
        )
        if stack.isEmpty {
            root = node
        } else {
            stack[stack.count - 1].children.append(node)
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        parseError = .parse(error.localizedDescription)
    }
}
