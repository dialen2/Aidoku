//
//  PythonSourceRunner.swift
//  Aidoku
//
//  Adapts a TVBox-style python `Spider` to the AidokuRunner contract.
//

import AidokuRunner
import Foundation

extension AidokuRunner.Source {
    static func python(key: String, script: String) -> AidokuRunner.Source {
        let name = (script as NSString).lastPathComponent
            .replacingOccurrences(of: ".py", with: "")
        let source = (try? String(contentsOfFile: script, encoding: .utf8)) ?? ""
        return .init(
            url: URL(fileURLWithPath: script),
            key: key,
            name: name,
            version: 1,
            languages: ["multi"],
            urls: [],
            contentRating: .safe,
            config: .init(languageSelectType: .single),
            staticListings: pythonListings(from: source),
            staticFilters: [],
            staticSettings: [],
            runner: PythonSourceRunner(sourceKey: key, scriptPath: script)
        )
    }

    /// TVBox spiders declare categories as literal `{"type_id": ..., "type_name": ...}`
    /// dicts in `homeContent`. Scrape them so the browser shows real listings
    /// without waiting on a network round trip.
    static func pythonListings(from source: String) -> [AidokuRunner.Listing] {
        let patterns = [
            #"type_id["']?\s*:\s*["']([^"']+)["'][^}]*?type_name["']?\s*:\s*["']([^"']+)["']"#,
            #"type_name["']?\s*:\s*["']([^"']+)["'][^}]*?type_id["']?\s*:\s*["']([^"']+)["']"#,
        ]
        var seen = Set<String>()
        var listings: [AidokuRunner.Listing] = []
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let text = source as NSString
            for match in regex.matches(in: source, range: NSRange(location: 0, length: text.length)) {
                guard match.numberOfRanges == 3 else { continue }
                let first = text.substring(with: match.range(at: 1))
                let second = text.substring(with: match.range(at: 2))
                let id = index == 0 ? first : second
                let title = index == 0 ? second : first
                guard !id.isEmpty, !title.isEmpty, seen.insert(id).inserted else { continue }
                listings.append(.init(id: id, name: title))
            }
        }
        if !listings.isEmpty { return listings }

        // Some spiders build the category table from a literal tuple list, e.g.
        //   [("同人/汉化", "1"), ("单行/汉化", "9")]
        // inside homeContent. Only scan that function body to avoid false hits.
        let all = source as NSString
        let anchor = all.range(of: "def homeContent")
        guard anchor.location != NSNotFound else { return [] }
        var body = all.substring(from: anchor.location)
        if let next = body.range(of: "\n    def ") {
            body = String(body[body.startIndex..<next.lowerBound])
        }
        let pairPattern = #"\(\s*["']([^"']{1,48})["']\s*,\s*["']([^"']{1,48})["']\s*\)"#
        guard let pairRegex = try? NSRegularExpression(pattern: pairPattern) else { return [] }
        let text = body as NSString
        for match in pairRegex.matches(in: body, range: NSRange(location: 0, length: text.length)) {
            guard match.numberOfRanges == 3 else { continue }
            let a = text.substring(with: match.range(at: 1))
            let b = text.substring(with: match.range(at: 2))
            let bIsNumeric = !b.isEmpty && b.allSatisfy({ $0.isNumber })
            let aIsNumeric = !a.isEmpty && a.allSatisfy({ $0.isNumber })
            let id: String
            let title: String
            if bIsNumeric && !aIsNumeric {
                id = b; title = a
            } else if aIsNumeric && !bIsNumeric {
                id = a; title = b
            } else {
                id = b; title = a
            }
            guard seen.insert(id).inserted else { continue }
            listings.append(.init(id: id, name: title))
        }
        return listings
    }
}

final class PythonSourceRunner: AidokuRunner.Runner {
    let features = AidokuRunner.SourceFeatures(
        providesListings: true,
        providesHome: true,
        dynamicFilters: false,
        dynamicSettings: false,
        dynamicListings: false,
        processesPages: false,
        processesCovers: false,
        providesImageRequests: true,
        providesPageDescriptions: false,
        providesBaseUrl: false
    )

    let sourceKey: String
    let scriptPath: String

    private var imageHeaders: [String: String] = [:]
    private let imageHeadersLock = NSLock()

    private func updateImageHeaders(_ headers: [String: String]) {
        imageHeadersLock.lock()
        imageHeaders = headers
        imageHeadersLock.unlock()
    }

    private func currentImageHeaders() -> [String: String] {
        imageHeadersLock.lock()
        defer { imageHeadersLock.unlock() }
        return imageHeaders
    }

    init(sourceKey: String, scriptPath: String) {
        self.sourceKey = sourceKey
        self.scriptPath = scriptPath
    }

    private func call(_ method: String, _ args: [String: Any]) async -> [String: Any] {
        let raw = await PythonRuntime.shared.dispatch(
            scriptPath: scriptPath,
            method: method,
            args: args
        )
        if let err = raw["error"] as? String {
            LogManager.logger.error("[python] \(self.sourceKey) \(method): \(err)")
        }
        return raw
    }

    private static func str(_ any: Any?) -> String? {
        switch any {
            case let s as String: return s.isEmpty ? nil : s
            case let n as NSNumber: return n.stringValue
            case let n as Int: return String(n)
            default: return nil
        }
    }

    private func entries(_ raw: [String: Any]) -> [[String: Any]] {
        guard let data = raw["data"] as? [String: Any] else { return [] }
        return data["list"] as? [[String: Any]] ?? []
    }

    private func manga(_ item: [String: Any]) -> AidokuRunner.Manga? {
        guard let key = Self.str(item["vod_id"]) else { return nil }
        guard let title = Self.str(item["vod_name"]) ?? Self.str(item["vod_id"]) else { return nil }
        return AidokuRunner.Manga(
            sourceKey: sourceKey,
            key: key,
            title: title,
            cover: Self.str(item["vod_pic"]),
            description: Self.str(item["vod_content"]) ?? Self.str(item["vod_remarks"])
        )
    }

    // MARK: - Runner

    func getHome() async throws -> AidokuRunner.Home {
        // TVBox has two home hooks and spiders populate only one of them:
        // - homeVideoContent() returns {list: [...]}  (the shelf)
        // - homeContent(filter)    returns {class: [...]} (the categories, list optional)
        // Neither is guaranteed, so probe in order and fall back to the first category.
        let home = await call("homeContent", ["filter": false])
        var list = entries(home).compactMap { manga($0) }

        if list.isEmpty {
            let video = await call("homeVideoContent", [String: Any]())
            list = entries(video).compactMap { manga($0) }
        }

        var firstTid: String?
        if let classes = (home["data"] as? [String: Any])?["class"] as? [[String: Any]] {
            firstTid = classes.first?["type_id"] as? String
        }

        if list.isEmpty, let tid = firstTid, !tid.isEmpty {
            let cat = await call("categoryContent", [
                "tid": tid,
                "pg": "1",
                "filter": false,
                "extend": [String: String](),
            ])
            list = entries(cat).compactMap { manga($0) }
        }

        guard !list.isEmpty else { return .init(components: []) }
        return .init(components: [
            .init(title: nil, value: .mangaList(entries: list.map { $0.intoLink() })),
        ])
    }

    func getMangaList(
        listing: AidokuRunner.Listing,
        page: Int
    ) async throws -> AidokuRunner.MangaPageResult {
        let raw = await call("categoryContent", [
            "tid": listing.id,
            "pg": String(page),
            "filter": false,
            "extend": [String: String](),
        ])
        let list = entries(raw).compactMap { manga($0) }
        return .init(entries: list, hasNextPage: !list.isEmpty)
    }

    func getSearchMangaList(
        query: String?,
        page: Int,
        filters: [AidokuRunner.FilterValue]
    ) async throws -> AidokuRunner.MangaPageResult {
        let raw = await call("searchContent", [
            "key": query ?? "",
            "quick": false,
            "pg": String(page),
        ])
        let list = entries(raw).compactMap { manga($0) }
        return .init(entries: list, hasNextPage: !list.isEmpty)
    }

    func getMangaUpdate(
        manga: AidokuRunner.Manga,
        needsDetails: Bool,
        needsChapters: Bool
    ) async throws -> AidokuRunner.Manga {
        var manga = manga
        let raw = await call("detailContent", ["ids": [manga.key]])
        guard let item = entries(raw).first else { return manga }

        if needsDetails {
            if let title = Self.str(item["vod_name"]) { manga.title = title }
            if let cover = Self.str(item["vod_pic"]) { manga.cover = cover }
            if let desc = Self.str(item["vod_content"]) { manga.description = desc }
        }

        if needsChapters {
            manga.chapters = parseChapters(Self.str(item["vod_play_url"]) ?? "")
        }
        return manga
    }

    private func parseChapters(_ playUrl: String) -> [AidokuRunner.Chapter] {
        guard !playUrl.isEmpty else { return [] }
        return playUrl.split(separator: "#").enumerated().compactMap { index, entry in
            let parts = entry.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return AidokuRunner.Chapter(
                key: String(parts[1]),
                title: String(parts[0]),
                chapterNumber: Float(index + 1)
            )
        }
    }

    func getPageList(
        manga: AidokuRunner.Manga,
        chapter: AidokuRunner.Chapter
    ) async throws -> [AidokuRunner.Page] {
        let raw = await call("playerContent", [
            "flag": "",
            "id": chapter.key,
            "vipFlags": [],
        ])
        guard let data = raw["data"] as? [String: Any] else { return [] }

        // TVBox comic sources put the image list in `url`; some use `data`.
        var blob = Self.str(data["url"]) ?? Self.str(data["data"]) ?? ""
        guard !blob.isEmpty else { return [] }

        // Standard TVBox comic convention: "pics://img1&&img2&&img3"
        if blob.hasPrefix("pics://") {
            blob = String(blob.dropFirst("pics://".count))
        }

        // Image hotlink protection: prefer headers embedded in the payload,
        // otherwise ask the spider for its getHeader().
        if let inline = data["header"] as? [String: String], !inline.isEmpty {
            updateImageHeaders(inline)
        } else {
            let headerRaw = await call("getHeader", [:])
            if headerRaw["error"] == nil, let headers = headerRaw["data"] as? [String: String] {
                updateImageHeaders(headers)
            }
        }

        let pieces: [String] = blob.contains("&&")
            ? blob.components(separatedBy: "&&")
            : blob.components(separatedBy: "#")

        return pieces.compactMap { piece -> AidokuRunner.Page? in
            let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let parsed = URL(string: text), parsed.scheme != nil else { return nil }
            return AidokuRunner.Page(content: .url(url: parsed))
        }
    }

    func getImageRequest(url: String, context: AidokuRunner.PageContext?) async throws -> URLRequest {
        guard let parsed = URL(string: url) else { throw URLError(.badURL) }
        var request = URLRequest(url: parsed)
        for (key, value) in currentImageHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }
}
