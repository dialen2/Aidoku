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
        .init(
            url: URL(fileURLWithPath: script),
            key: key,
            name: (script as NSString).lastPathComponent.replacingOccurrences(of: ".py", with: ""),
            version: 1,
            languages: ["multi"],
            urls: [],
            contentRating: .safe,
            config: .init(languageSelectType: .single),
            staticListings: [],
            staticFilters: [],
            staticSettings: [],
            runner: PythonSourceRunner(scriptPath: script)
        )
    }
}

final class PythonSourceRunner: AidokuRunner.Runner {
    static let sourceKey = "python"

    let features = AidokuRunner.SourceFeatures(
        providesListings: false,
        providesHome: false,
        dynamicFilters: false,
        dynamicSettings: false,
        dynamicListings: false,
        processesPages: false,
        processesCovers: false,
        providesImageRequests: false,
        providesPageDescriptions: false,
        providesBaseUrl: false
    )

    let scriptPath: String

    init(scriptPath: String) {
        self.scriptPath = scriptPath
    }

    private func call(_ method: String, _ args: [String: Any]) -> [String: Any] {
        let raw = PythonRuntime.shared.dispatch(scriptPath: scriptPath, method: method, args: args)
        if let err = raw["error"] as? String {
            LogManager.logger.error("[python] \(method): \(err)")
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
            sourceKey: Self.sourceKey,
            key: key,
            title: title,
            cover: Self.str(item["vod_pic"]),
            description: Self.str(item["vod_content"]) ?? Self.str(item["vod_remarks"])
        )
    }

    // MARK: - Runner

    func getSearchMangaList(
        query: String?,
        page: Int,
        filters: [AidokuRunner.FilterValue]
    ) async throws -> AidokuRunner.MangaPageResult {
        let raw = call("searchContent", [
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
        let raw = call("detailContent", ["ids": [manga.key]])
        guard let item = entries(raw).first else { return manga }

        if needsDetails {
            if let title = Self.str(item["vod_name"]) { manga.title = title }
            if let cover = Self.str(item["vod_pic"]) { manga.cover = cover }
            if let desc = Self.str(item["vod_content"]) { manga.description = desc }
            if let remarks = Self.str(item["vod_remarks"]) {
                manga.description = (manga.description ?? "") + (manga.description == nil ? "" : "\n") + remarks
            }
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
        let raw = call("playerContent", [
            "flag": "",
            "id": chapter.key,
            "vipFlags": [],
        ])
        guard let data = raw["data"] as? [String: Any],
              let url = Self.str(data["url"]) else {
            return []
        }
        return url
            .split(separator: "#")
            .compactMap { piece -> AidokuRunner.Page? in
                let text = String(piece)
                guard let parsed = URL(string: text) else { return nil }
                return AidokuRunner.Page(content: .url(url: parsed))
            }
    }
}
