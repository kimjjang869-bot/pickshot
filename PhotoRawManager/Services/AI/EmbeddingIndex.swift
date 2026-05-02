//
//  EmbeddingIndex.swift
//  PhotoRawManager
//
//  v8.9: CLIP 임베딩 영속 저장 + 코사인 유사도 검색.
//  SQLite 기반 (URL, mtime, 512-dim Float32 BLOB).
//  폴더당 별도 DB 파일로 isolation.
//

import Foundation
import SQLite3

final class EmbeddingIndex {
    static let shared = EmbeddingIndex()

    private var db: OpaquePointer?
    private var currentFolderPath: String?
    private let lock = NSLock()
    private let dim = 512  // MobileCLIP-BLT

    /// v8.9 perf: 폴더 전체 임베딩 메모리 캐시 — topK 반복 호출 시 DB 재로드 방지.
    ///   폴더 전환 / upsert / 삭제 시 무효화.
    private var _allCache: [(url: URL, vec: [Float])]?
    private var _allCacheFolder: String?

    private init() {}

    // MARK: - DB lifecycle

    /// 지정 폴더용 DB 를 열거나 생성. 다른 폴더로 전환 시 이전 DB 자동 close.
    func open(for folderURL: URL) {
        lock.lock(); defer { lock.unlock() }

        let folderPath = folderURL.path
        if currentFolderPath == folderPath, db != nil { return }

        closeLocked()

        let dbPath = dbFileURL(for: folderURL).path
        try? FileManager.default.createDirectory(
            at: dbFileURL(for: folderURL).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(dbPath, &handle, flags, nil)
        guard status == SQLITE_OK else {
            plog("[EMB-IDX] open 실패: \(dbPath) status=\(status)\n")
            return
        }
        db = handle
        currentFolderPath = folderPath

        // 성능 pragmas
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA temp_store=MEMORY;")
        exec("PRAGMA cache_size=-16000;")  // 16MB

        // Schema
        exec("""
            CREATE TABLE IF NOT EXISTS embeddings (
                path TEXT PRIMARY KEY,
                mtime REAL NOT NULL,
                dim INTEGER NOT NULL,
                embedding BLOB NOT NULL,
                created_at REAL NOT NULL
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_mtime ON embeddings(mtime);")

        plog("[EMB-IDX] opened \(dbPath) for \(folderURL.lastPathComponent)\n")
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closeLocked()
    }

    private func closeLocked() {
        if let h = db {
            sqlite3_close_v2(h)
            db = nil
            currentFolderPath = nil
        }
        invalidateAllCache()  // v8.9: 폴더 전환 시 캐시 폐기
    }

    private func dbFileURL(for folderURL: URL) -> URL {
        // 캐시 디렉토리에 폴더 path hash 기반 파일명
        let hash = folderURL.path.data(using: .utf8)?.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-") ?? "default"
        let truncated = String(hash.prefix(80))
        let cacheDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PickShot/EmbeddingIndex", isDirectory: true)
        return cacheDir.appendingPathComponent("\(truncated).sqlite3")
    }

    // MARK: - Upsert

    /// 임베딩 저장 (이미 있으면 덮어쓰기). mtime 이 동일하면 스킵.
    func upsert(url: URL, mtime: TimeInterval, embedding: [Float]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let db = db, embedding.count == dim else { return false }

        // 기존 mtime 체크
        if let existingMtime = getMtimeLocked(path: url.path), abs(existingMtime - mtime) < 0.1 {
            return false  // unchanged
        }

        var stmt: OpaquePointer?
        let sql = """
            INSERT OR REPLACE INTO embeddings (path, mtime, dim, embedding, created_at)
            VALUES (?, ?, ?, ?, ?);
        """
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, url.path, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, mtime)
        sqlite3_bind_int(stmt, 3, Int32(dim))

        _ = embedding.withUnsafeBufferPointer { buf in
            sqlite3_bind_blob(stmt, 4, buf.baseAddress, Int32(buf.count * MemoryLayout<Float>.size), SQLITE_TRANSIENT)
        }
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)

        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { invalidateAllCache() }  // v8.9: 쓰기 후 캐시 무효화
        return rc == SQLITE_DONE
    }

    private func getMtimeLocked(path: String) -> TimeInterval? {
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT mtime FROM embeddings WHERE path = ? LIMIT 1;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_double(stmt, 0)
        }
        return nil
    }

    /// v8.9 fix: 저장된 mtime 조회 (재인덱싱 필요 여부 판단용)
    func getStoredMtime(url: URL) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return getMtimeLocked(path: url.path)
    }

    // MARK: - Retrieval

    /// 지정 URL 의 임베딩 리턴.
    func get(url: URL) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT embedding, dim FROM embeddings WHERE path = ? LIMIT 1;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, url.path, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let storedDim = Int(sqlite3_column_int(stmt, 1))
        guard storedDim == dim else { return nil }
        let bytes = sqlite3_column_blob(stmt, 0)
        let len = Int(sqlite3_column_bytes(stmt, 0))
        guard len == dim * MemoryLayout<Float>.size, let bytes = bytes else { return nil }
        return bytes.withMemoryRebound(to: Float.self, capacity: dim) { ptr in
            Array(UnsafeBufferPointer(start: ptr, count: dim))
        }
    }

    /// v8.9: 메모리 캐시 사용 loadAll. 폴더 단위 유지, 무효화 시 재로드.
    private func cachedAll() -> [(url: URL, vec: [Float])] {
        lock.lock()
        if let cache = _allCache, _allCacheFolder == currentFolderPath {
            lock.unlock()
            return cache
        }
        lock.unlock()
        let fresh = loadAll().map { (url: $0.url, vec: $0.embedding) }
        lock.lock()
        _allCache = fresh
        _allCacheFolder = currentFolderPath
        lock.unlock()
        return fresh
    }

    /// 캐시 무효화 — upsert/remove 후 호출.
    private func invalidateAllCache() {
        _allCache = nil
        _allCacheFolder = nil
    }

    /// 전체 임베딩을 메모리로 로드 (top-K 검색 전 준비).
    /// 규모 10,000장 × 2KB = 20MB 정도라 메모리 로드 가능.
    func loadAll() -> [(url: URL, embedding: [Float])] {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return [] }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT path, embedding FROM embeddings WHERE dim = ?;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(dim))

        var result: [(URL, [Float])] = []
        result.reserveCapacity(10000)
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cPath = sqlite3_column_text(stmt, 0) else { continue }
            let path = String(cString: cPath)
            let bytes = sqlite3_column_blob(stmt, 1)
            let len = Int(sqlite3_column_bytes(stmt, 1))
            guard len == dim * MemoryLayout<Float>.size, let bytes = bytes else { continue }
            let vec = bytes.withMemoryRebound(to: Float.self, capacity: dim) { ptr in
                Array(UnsafeBufferPointer(start: ptr, count: dim))
            }
            result.append((URL(fileURLWithPath: path), vec))
        }
        return result
    }

    /// Top-K 유사도 검색 (브루트포스 코사인). 10,000장 기준 ~50ms.
    /// v8.9 perf: 폴더 단위 메모리 캐시 사용 — 반복 검색 시 DB 재로드 없음.
    func topK(queryEmbedding: [Float], k: Int = 50, excludePath: String? = nil) -> [(url: URL, score: Float)] {
        let all = cachedAll()
        guard queryEmbedding.count == dim else { return [] }

        // 각 임베딩과 코사인 유사도 (둘 다 L2-normalized 가정 → dot product = cosine)
        var scored: [(URL, Float)] = []
        scored.reserveCapacity(all.count)
        for (url, vec) in all {
            if url.path == excludePath { continue }
            var dot: Float = 0
            for i in 0..<dim { dot += queryEmbedding[i] * vec[i] }
            scored.append((url, dot))
        }
        scored.sort { $0.1 > $1.1 }
        return Array(scored.prefix(k))
    }

    /// 폴더에서 삭제된 파일의 임베딩 정리.
    func removeStale(existingPaths: Set<String>) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return 0 }

        // 현재 DB 안의 모든 path 조회
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT path FROM embeddings;", -1, &stmt, nil)
        var allPaths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cPath = sqlite3_column_text(stmt, 0) {
                allPaths.append(String(cString: cPath))
            }
        }
        sqlite3_finalize(stmt)

        let toDelete = allPaths.filter { !existingPaths.contains($0) }
        if toDelete.isEmpty { return 0 }

        exec("BEGIN;")
        var delStmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM embeddings WHERE path = ?;", -1, &delStmt, nil)
        for path in toDelete {
            sqlite3_reset(delStmt)
            sqlite3_bind_text(delStmt, 1, path, -1, SQLITE_TRANSIENT)
            sqlite3_step(delStmt)
        }
        sqlite3_finalize(delStmt)
        exec("COMMIT;")
        plog("[EMB-IDX] stale 정리: \(toDelete.count)건\n")
        return toDelete.count
    }

    // MARK: - Stats

    /// 현재 DB 의 총 엔트리 수.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        guard let db = db else { return 0 }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM embeddings;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Helpers

    private func exec(_ sql: String) {
        guard let db = db else { return }
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, sql, nil, nil, &err)
        if let err = err {
            plog("[EMB-IDX] SQL error: \(String(cString: err))\n")
            sqlite3_free(err)
        }
    }
}

// SQLite transient/static constants
private let SQLITE_STATIC = unsafeBitCast(0, to: sqlite3_destructor_type.self)
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
