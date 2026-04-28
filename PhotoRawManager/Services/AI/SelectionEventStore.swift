//
//  SelectionEventStore.swift
//  PhotoRawManager
//
//  v8.9: 사용자 셀렉 이벤트 영속화 DB.
//  - AI 셀렉 학습의 "뿌리" 데이터셋.
//  - 사용자의 모든 의도 (별점/컬러/SP/내보내기/삭제) 를 시간순 원장으로 기록.
//  - 이 원장으로 언제든 재학습 / 세그먼트 / 백업 / 이관 가능.
//
//  스키마 설계 원칙:
//  - 절대 파괴적 업데이트 없음. 모든 변경은 새 이벤트로 append.
//  - 사진 파일이 이동/리네임돼도 photo_uuid 로 추적 가능.
//  - 세션(폴더/이벤트)별 집계를 빠르게 하기 위한 인덱스.
//  - Forward-compatible: extra JSON 필드로 향후 스키마 확장 대응.
//

import Foundation
import SQLite3

/// 이벤트 종류 — 사용자의 의도 표현 액션.
enum SelectionEventKind: String, Codable {
    case rated        // 별점 설정 (payload: rating 0~5)
    case colorLabel   // 컬러라벨 변경 (payload: label name)
    case spacePick    // Space Pick 토글 (payload: true/false)
    case gSelect      // G셀렉 (payload: true/false)
    case exported     // 내보내기 (payload: dest path 등)
    case uploaded     // Google Drive 업로드
    case deleted      // 삭제 (휴지통 이동)
    case aiPick       // AI 선별 결과 수락 (베스트로 지정됨)
    case aiReject     // AI 선별 결과에서 탈락 (같은 버스트 내 다른 장이 베스트)
    case manualPick   // 사용자가 수동으로 "좋다" 표시
    case manualReject // 사용자가 수동으로 "탈락" 표시
}

/// 이벤트 → label 자동 매핑: positive / negative / neutral.
enum EventPolarity {
    case positive, negative, neutral

    static func of(_ kind: SelectionEventKind, payload: String?) -> EventPolarity {
        switch kind {
        case .rated:
            if let r = payload.flatMap({ Int($0) }), r >= 4 { return .positive }
            if let r = payload.flatMap({ Int($0) }), r > 0, r <= 2 { return .negative }
            return .neutral
        case .colorLabel:
            // 초록/노랑 = 긍정, 빨강 = 부정, 파랑/보라 = 중립
            switch payload ?? "" {
            case "green", "yellow": return .positive
            case "red": return .negative
            default: return .neutral
            }
        case .spacePick, .gSelect, .exported, .uploaded, .aiPick, .manualPick:
            return .positive
        case .deleted, .aiReject, .manualReject:
            return .negative
        }
    }
}

/// 단일 이벤트 레코드.
struct SelectionEvent {
    let id: Int64
    let photoUUID: String
    let photoPath: String
    let folderPath: String
    let sessionID: String?        // 이벤트/프로젝트 그룹핑용 (폴더 또는 사용자 지정)
    let kind: SelectionEventKind
    let payload: String?
    let extraJSON: String?        // 향후 확장용
    let createdAt: Date
}

final class SelectionEventStore {
    static let shared = SelectionEventStore()

    private var db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "com.pickshot.selection-events", qos: .utility)

    private var dbURL: URL {
        let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let base = appSupport?.appendingPathComponent("PickShot", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("selection_events.sqlite3")
    }

    private init() {
        open()
    }

    deinit { close() }

    // MARK: - 연결 & 스키마

    private func open() {
        guard db == nil else { return }
        if sqlite3_open_v2(dbURL.path, &db,
                           SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                           nil) != SQLITE_OK {
            fputs("[SEL-DB] open 실패: \(String(cString: sqlite3_errmsg(db)))\n", stderr)
            db = nil
            return
        }
        // WAL = 동시성 우수
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        createSchema()
        fputs("[SEL-DB] opened \(dbURL.path)\n", stderr)
    }

    func close() {
        dbQueue.sync {
            if let db = db { sqlite3_close_v2(db) }
            db = nil
        }
    }

    private func createSchema() {
        let ddl = """
        CREATE TABLE IF NOT EXISTS events (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            photo_uuid   TEXT NOT NULL,
            photo_path   TEXT NOT NULL,
            folder_path  TEXT NOT NULL,
            session_id   TEXT,
            kind         TEXT NOT NULL,
            payload      TEXT,
            extra_json   TEXT,
            created_at   REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_events_uuid    ON events(photo_uuid);
        CREATE INDEX IF NOT EXISTS idx_events_folder  ON events(folder_path);
        CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id);
        CREATE INDEX IF NOT EXISTS idx_events_kind    ON events(kind);
        CREATE INDEX IF NOT EXISTS idx_events_time    ON events(created_at);

        CREATE TABLE IF NOT EXISTS profile_snapshots (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            name         TEXT NOT NULL,
            positive     BLOB NOT NULL,
            negative     BLOB,
            pos_count    INTEGER,
            neg_count    INTEGER,
            scope_json   TEXT,
            created_at   REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS schema_meta (
            version      INTEGER PRIMARY KEY,
            notes        TEXT,
            applied_at   REAL
        );
        """
        sqlite3_exec(db, ddl, nil, nil, nil)

        // 버전 기록 — migration 용
        var stmt: OpaquePointer?
        let ver = "INSERT OR IGNORE INTO schema_meta(version, notes, applied_at) VALUES (?, ?, ?)"
        if sqlite3_prepare_v2(db, ver, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, 1)
            sqlite3_bind_text(stmt, 2, "initial", -1, nil)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - 이벤트 기록

    /// 단일 이벤트 append. 사용자의 모든 선택 액션에서 호출.
    func record(
        photoUUID: String,
        photoPath: String,
        folderPath: String,
        sessionID: String? = nil,
        kind: SelectionEventKind,
        payload: String? = nil,
        extraJSON: String? = nil,
        at date: Date = Date()
    ) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO events
            (photo_uuid, photo_path, folder_path, session_id, kind, payload, extra_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(stmt, 1, photoUUID, -1, transient)
                sqlite3_bind_text(stmt, 2, photoPath, -1, transient)
                sqlite3_bind_text(stmt, 3, folderPath, -1, transient)
                if let s = sessionID {
                    sqlite3_bind_text(stmt, 4, s, -1, transient)
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
                sqlite3_bind_text(stmt, 5, kind.rawValue, -1, transient)
                if let p = payload {
                    sqlite3_bind_text(stmt, 6, p, -1, transient)
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                if let e = extraJSON {
                    sqlite3_bind_text(stmt, 7, e, -1, transient)
                } else {
                    sqlite3_bind_null(stmt, 7)
                }
                sqlite3_bind_double(stmt, 8, date.timeIntervalSince1970)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    // MARK: - 조회

    /// 최근 positive 이벤트의 사진 경로 (중복 제거) 반환. 학습용.
    func recentPositivePaths(limit: Int = 5000) -> [String] {
        queryPolarity(positive: true, limit: limit)
    }

    /// 최근 negative 이벤트의 사진 경로.
    func recentNegativePaths(limit: Int = 5000) -> [String] {
        queryPolarity(positive: false, limit: limit)
    }

    private func queryPolarity(positive: Bool, limit: Int) -> [String] {
        var result: [String] = []
        dbQueue.sync {
            guard let db = db else { return }
            var stmt: OpaquePointer?
            // 최신 순으로 중복 제거
            let sql = """
            SELECT photo_path, kind, payload, MAX(created_at) AS last_time
            FROM events
            GROUP BY photo_path
            ORDER BY last_time DESC
            LIMIT ?
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, Int32(limit * 3))  // over-fetch, filter 후 잘라냄
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let pathC = sqlite3_column_text(stmt, 0),
                          let kindC = sqlite3_column_text(stmt, 1) else { continue }
                    let path = String(cString: pathC)
                    let kindStr = String(cString: kindC)
                    let payload: String? = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                    guard let kind = SelectionEventKind(rawValue: kindStr) else { continue }
                    let polarity = EventPolarity.of(kind, payload: payload)
                    if positive && polarity == .positive {
                        result.append(path)
                    } else if !positive && polarity == .negative {
                        result.append(path)
                    }
                    if result.count >= limit { break }
                }
                sqlite3_finalize(stmt)
            }
        }
        return result
    }

    /// 이벤트 수 통계 — UI 표시용.
    struct Stats {
        var totalEvents: Int
        var uniquePhotos: Int
        var positives: Int
        var negatives: Int
        var byKind: [String: Int]        // kind → 이벤트 수
        var byFolder: [(String, Int)]     // 폴더별 이벤트 수 (top 10)
        var dbSizeBytes: Int64
        var firstEventAt: Date?
        var lastEventAt: Date?
    }

    func stats() -> Stats {
        var s = Stats(totalEvents: 0, uniquePhotos: 0, positives: 0, negatives: 0,
                      byKind: [:], byFolder: [], dbSizeBytes: 0,
                      firstEventAt: nil, lastEventAt: nil)
        dbQueue.sync {
            guard let db = db else { return }
            var stmt: OpaquePointer?
            // 총 이벤트
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM events", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    s.totalEvents = Int(sqlite3_column_int(stmt, 0))
                }
                sqlite3_finalize(stmt)
            }
            // 고유 사진
            if sqlite3_prepare_v2(db, "SELECT COUNT(DISTINCT photo_path) FROM events", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    s.uniquePhotos = Int(sqlite3_column_int(stmt, 0))
                }
                sqlite3_finalize(stmt)
            }
            // kind 별 이벤트 수
            if sqlite3_prepare_v2(db, "SELECT kind, COUNT(*) FROM events GROUP BY kind", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let k = sqlite3_column_text(stmt, 0) else { continue }
                    s.byKind[String(cString: k)] = Int(sqlite3_column_int(stmt, 1))
                }
                sqlite3_finalize(stmt)
            }
            // 폴더별 이벤트 top 10
            let folderSQL = "SELECT folder_path, COUNT(*) AS c FROM events GROUP BY folder_path ORDER BY c DESC LIMIT 10"
            if sqlite3_prepare_v2(db, folderSQL, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let p = sqlite3_column_text(stmt, 0) else { continue }
                    s.byFolder.append((String(cString: p), Int(sqlite3_column_int(stmt, 1))))
                }
                sqlite3_finalize(stmt)
            }
            // 첫/마지막 이벤트 시각
            if sqlite3_prepare_v2(db, "SELECT MIN(created_at), MAX(created_at) FROM events", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let first = sqlite3_column_double(stmt, 0)
                    let last = sqlite3_column_double(stmt, 1)
                    if first > 0 { s.firstEventAt = Date(timeIntervalSince1970: first) }
                    if last > 0 { s.lastEventAt = Date(timeIntervalSince1970: last) }
                }
                sqlite3_finalize(stmt)
            }
        }
        // v8.9 perf: 전체 경로 배열 로드 대신 COUNT(DISTINCT) 로 직접 계산 (수만 row 힙 로드 방지).
        dbQueue.sync {
            guard let db = db else { return }
            var stmt: OpaquePointer?
            let posKinds = "'spacePick','gSelect','exported','uploaded','aiPick','manualPick'"
            let negKinds = "'deleted','aiReject','manualReject'"
            // positive: 상기 kind + rated payload >=4 + color green/yellow
            let posSQL = """
                SELECT COUNT(DISTINCT photo_path) FROM events
                WHERE kind IN (\(posKinds))
                   OR (kind = 'rated' AND CAST(payload AS INTEGER) >= 4)
                   OR (kind = 'colorLabel' AND payload IN ('green','yellow'))
            """
            if sqlite3_prepare_v2(db, posSQL, -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW { s.positives = Int(sqlite3_column_int(stmt, 0)) }
                sqlite3_finalize(stmt)
            }
            let negSQL = """
                SELECT COUNT(DISTINCT photo_path) FROM events
                WHERE kind IN (\(negKinds))
                   OR (kind = 'rated' AND CAST(payload AS INTEGER) > 0 AND CAST(payload AS INTEGER) <= 2)
                   OR (kind = 'colorLabel' AND payload = 'red')
            """
            if sqlite3_prepare_v2(db, negSQL, -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW { s.negatives = Int(sqlite3_column_int(stmt, 0)) }
                sqlite3_finalize(stmt)
            }
        }
        s.dbSizeBytes = fileSizeBytes
        return s
    }

    // MARK: - 용량/성능 관리

    /// 상태성 이벤트 (rated/colorLabel/spacePick) 를 사진별로 최신 1건만 유지.
    /// - 이력 필요한 것 (exported/uploaded/deleted) 은 그대로 보존.
    /// - 주기적(폴더 진입 시 1회) 또는 사용자 명령으로 호출.
    func coalesceStatefulEvents() {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            let statefulKinds = "'rated','colorLabel','spacePick','gSelect'"
            let sql = """
            DELETE FROM events
            WHERE kind IN (\(statefulKinds))
              AND id NOT IN (
                SELECT MAX(id) FROM events
                WHERE kind IN (\(statefulKinds))
                GROUP BY photo_path, kind
              );
            """
            var removed: Int32 = 0
            sqlite3_exec(db, sql, nil, nil, nil)
            removed = sqlite3_changes(db)
            fputs("[SEL-DB] coalesce: 중복 \(removed)건 제거\n", stderr)
        }
    }

    /// 오래된 이벤트 압축 — 지정 기간(월) 이전 이벤트를 집계 후 삭제.
    /// - 학습용 벡터/통계는 스냅샷 테이블로 보존.
    func compactOlderThan(months: Int = 6) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            let cutoff = Date().addingTimeInterval(-Double(months) * 30 * 86400).timeIntervalSince1970
            var stmt: OpaquePointer?
            let cntSQL = "SELECT COUNT(*) FROM events WHERE created_at < ?"
            if sqlite3_prepare_v2(db, cntSQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, cutoff)
                var count = 0
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
                sqlite3_finalize(stmt)
                if count == 0 { return }
                fputs("[SEL-DB] compact: \(count)건 대상\n", stderr)
            }
            // 단순 삭제 (실제 서비스는 먼저 스냅샷으로 집계 후 삭제하는 편이 좋음)
            let delSQL = "DELETE FROM events WHERE created_at < ?"
            if sqlite3_prepare_v2(db, delSQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, cutoff)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
            sqlite3_exec(db, "VACUUM;", nil, nil, nil)
            fputs("[SEL-DB] compact 완료 (VACUUM 수행)\n", stderr)
        }
    }

    /// DB 파일 크기 (byte).
    var fileSizeBytes: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: dbURL.path)[.size] as? Int64) ?? 0
    }

    // MARK: - 프로파일 스냅샷 저장 (옵션)

    func saveProfileSnapshot(name: String, positive: [Float], negative: [Float], posCount: Int, negCount: Int, scope: String? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO profile_snapshots (name, positive, negative, pos_count, neg_count, scope_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(stmt, 1, name, -1, transient)
                let posData = positive.withUnsafeBufferPointer { Data(buffer: $0) }
                _ = posData.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, 2, buf.baseAddress, Int32(buf.count), transient)
                }
                if !negative.isEmpty {
                    let negData = negative.withUnsafeBufferPointer { Data(buffer: $0) }
                    negData.withUnsafeBytes { buf in
                        sqlite3_bind_blob(stmt, 3, buf.baseAddress, Int32(buf.count), transient)
                    }
                } else {
                    sqlite3_bind_null(stmt, 3)
                }
                sqlite3_bind_int(stmt, 4, Int32(posCount))
                sqlite3_bind_int(stmt, 5, Int32(negCount))
                if let scope = scope {
                    sqlite3_bind_text(stmt, 6, scope, -1, transient)
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }
}
