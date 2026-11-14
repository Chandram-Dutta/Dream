import Foundation
import NaturalLanguage
import SwiftData

/// How the user's pages relate: by what they're about (the people, places, projects and works
/// understanding the request named, `SavedSurface.subjects`), and by which page each went on
/// from. It's Dream's memory of what it has looked into for someone, all on their iPhone, and
/// what it's used for:
/// - understanding a request: "the GTM plan" is read with the earlier page made from those
///   Notion notes in front of it, and what was found for it (`GapCheck.relatedPages`);
/// - each page's thread (where it came from) and its related pages;
/// - the map of everything made (PageMapView.swift), and suggestions that go on from it.
enum PageGraph {
    /// A page as the graph sees it.
    struct Node: Identifiable, Hashable {
        var id: UUID
        var title: String
        var intent: String
        var subjects: [String]
        var parent: UUID?
        var found: String
        var updatedAt: Date
        var isStarred = false
    }

    /// A subject that several pages share, and those pages.
    struct Cluster: Hashable {
        var subject: String
        var pages: [UUID]
    }

    // MARK: - Relating

    /// The pages most related to `node`: those it went on from or that went on from it first,
    /// then those sharing what they're about, then those sharing the most words; newer first
    /// among equals.
    static func related(to node: Node, in nodes: [Node], limit: Int = 4) -> [Node] {
        let mine = keys(node)
        let words = ScreenMemory.terms(node.title + " " + node.intent)
        let scored = nodes.compactMap { other -> (Node, Double)? in
            guard other.id != node.id else { return nil }
            var score = 0.0
            if other.id == node.parent || other.parent == node.id { score += 10 }
            if other.parent != nil, other.parent == node.parent { score += 4 }
            let shared: Int = keys(other).intersection(mine).count
            score += Double(shared) * 3
            let alike: Double = ScreenMemory.similarity(words, ScreenMemory.terms(other.title + " " + other.intent))
            score += alike * 2
            return score >= 1 ? (other, score) : nil
        }
        return ranked(scored, limit: limit)
    }

    /// The best scored first, newer first among equals.
    private static func ranked(_ scored: [(Node, Double)], limit: Int) -> [Node] {
        let sorted = scored.sorted { (a: (Node, Double), b: (Node, Double)) -> Bool in
            a.1 != b.1 ? a.1 > b.1 : a.0.updatedAt > b.0.updatedAt
        }
        return sorted.prefix(limit).map { $0.0 }
    }

    /// The earlier pages a request is likely about: ones whose subjects it names, or whose
    /// request and title it shares most of its words with.
    static func related(toRequest request: String, in nodes: [Node], limit: Int = 3) -> [Node] {
        let asked = key(request)
        let words = ScreenMemory.terms(request)
        guard !words.isEmpty else { return [] }
        let scored = nodes.compactMap { node -> (Node, Double)? in
            let named: Int = keys(node).filter { $0.count >= 3 && contains(asked, $0) }.count
            let shared: Double = ScreenMemory.similarity(words, ScreenMemory.terms(node.title + " " + node.intent))
            let score: Double = Double(named) * 2 + (shared >= 0.4 ? shared * 2 : 0)
            return score >= 0.8 ? (node, score) : nil
        }
        return ranked(scored, limit: limit)
    }

    /// What understanding a request is told about an earlier page: its title, request and what
    /// was found for it, short.
    static func described(_ node: Node) -> String {
        let found = node.found.count > 500 ? String(node.found.prefix(500)) + "…" : node.found
        return "\"\(node.title)\" (asked as \"\(node.intent)\")" + (found.isEmpty ? "" : ": " + found.replacingOccurrences(of: "\n", with: "; "))
    }

    /// The pages this one went on from, oldest first, then this one.
    static func thread(of node: Node, in nodes: [Node]) -> [Node] {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chain = [node]
        var seen: Set<UUID> = [node.id]
        while let parent = chain.first?.parent, let earlier = byID[parent], seen.insert(parent).inserted {
            chain.insert(earlier, at: 0)
        }
        return chain
    }

    /// The pages that went on from this one, newest first.
    static func children(of node: Node, in nodes: [Node]) -> [Node] {
        nodes.filter { $0.parent == node.id }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Subjects shared by at least two pages, the most shared first: the map's hubs.
    static func clusters(_ nodes: [Node]) -> [Cluster] {
        var pages: [String: [UUID]] = [:]
        var names: [String: String] = [:]
        for node in nodes {
            for subject in subjects(of: node) {
                let key = key(subject)
                guard !key.isEmpty else { continue }
                if !(pages[key]?.contains(node.id) ?? false) { pages[key, default: []].append(node.id) }
                names[key] = names[key] ?? subject
            }
        }
        return pages.filter { $0.value.count >= 2 }
            .map { Cluster(subject: names[$0.key] ?? $0.key, pages: $0.value) }
            .sorted { $0.pages.count != $1.pages.count ? $0.pages.count > $1.pages.count : $0.subject < $1.subject }
    }

    // MARK: - Subjects

    /// What a page is about: what understanding named, or for a page made before it did, the
    /// names in its title and request.
    static func subjects(of node: Node) -> [String] {
        if !node.subjects.isEmpty { return node.subjects }
        return names(in: node.title + ". " + node.intent)
    }

    /// People, places and organisations named in a text.
    static func names(in text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var found: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
                let name = String(text[range])
                if !found.contains(where: { key($0) == key(name) }) { found.append(name) }
            }
            return true
        }
        return found
    }

    private static func keys(_ node: Node) -> Set<String> {
        Set(subjects(of: node).map(key).filter { !$0.isEmpty })
    }

    /// A subject as it's compared: lowercased letters and numbers, single spaces.
    static func key(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    /// Whether `text` holds `subject` as whole words.
    private static func contains(_ text: String, _ subject: String) -> Bool {
        (" " + text + " ").contains(" " + subject + " ")
    }
}

extension SavedSurface {
    var node: PageGraph.Node {
        PageGraph.Node(id: id, title: surface.title, intent: intent, subjects: subjects, parent: parentID, found: found, updatedAt: updatedAt, isStarred: isStarred)
    }
}

extension PageGraph {
    /// Every page of the user's own, newest first, for the graph.
    @MainActor
    static func pages(in context: ModelContext) -> [SavedSurface] {
        let descriptor = FetchDescriptor<SavedSurface>(predicate: #Predicate { $0.sharedFrom == nil }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }
}
