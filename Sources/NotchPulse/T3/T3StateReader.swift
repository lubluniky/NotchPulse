import Foundation

// Reads T3 Code's orchestration v2 projections (statev2.sqlite) and maps them to AgentThread values.
//
// Status vocabulary (from T3's own schema, server 0.1.10):
//   runs.status                 preparing | queued | starting | running | waiting | completed |
//                               interrupted | failed | cancelled | rolled_back
//                               ("waiting" = turn finished but background work still pending; T3 counts
//                                preparing/starting/running/waiting as active work)
//   runtime_requests.status     pending | resolved | expired | cancelled   (unresolved == 'pending')
//   runtime_requests.kind       command | file-read | file-change | mcp-elicitation | permission |
//                               dynamic_tool_call | user_input | auth_refresh
//   subagents.status            idle | pending | running | waiting | completed | failed | cancelled | interrupted
//   turn_items secret_request / link_request with status 'waiting' are user-only input cards.
//
// Mapping (mirrors T3's thread-shell logic):
//   needsInput  pending runtime request, or a waiting secret card inside an active run, or a waiting
//               link card the user has not written past (or a subagent of the thread needs input)
//   running     an active run (preparing/starting/running/waiting) or an unheld queued run;
//               provider-native subagent threads (no runs of their own) use their subagent row status;
//               a thread whose live subagents keep working after its own run ended is also running
//   completed   latest run completed
//   failed      latest run failed / interrupted / cancelled-after-start
//   idle        no runs (or nothing recognisable)
//
// Confined to T3Monitor's serial queue.
final class T3StateReader {
    static let maxThreads = 10
    static let previewLimit = 140

    private let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    struct Result {
        var threads: [AgentThread]
        var runningCount: Int
        var needsInputCount: Int
    }

    /// - Parameter serverOnline: when false nothing can be running or answerable, so stale
    ///   active rows (T3 quit mid-run) fall back to the last terminal run status.
    func read(_ db: T3SQLiteConnection, serverOnline: Bool) throws -> Result {
        try db.readTransaction {
            var candidates = try loadCandidates(db)
            let pendingSource = serverOnline ? resolveStates(&candidates) : resolveOfflineStates(&candidates)

            let topLevel = candidates.filter { !$0.isSubagent }
            let runningCount = topLevel.filter { $0.state == .running }.count
            let needsInputCount = topLevel.filter { $0.state == .needsInput }.count

            let selected = candidates
                .filter { !$0.isSubagent || $0.state == .running || $0.state == .needsInput }
                .sorted(by: Self.displayOrder)
                .prefix(Self.maxThreads)

            var threads: [AgentThread] = []
            threads.reserveCapacity(selected.count)
            for candidate in selected {
                threads.append(try loadThread(db, candidate, pendingSourceId: pendingSource[candidate.id]))
            }
            // Detail queries can move updatedAt forward; keep the documented order.
            threads.sort(by: Self.displayOrder)
            return Result(threads: threads, runningCount: runningCount, needsInputCount: needsInputCount)
        }
    }

    // MARK: - Phase 1: cheap per-thread status for every visible thread

    private struct Candidate {
        let id: String
        let updatedAt: Date?
        let isSubagent: Bool
        let parentId: String?
        let activeRunStatus: String?
        let latestRunStatus: String?
        let hasPendingRequest: Bool
        let hasPendingSecret: Bool
        let hasPendingLink: Bool
        let ownSubagentStatus: String?
        let ownSubagentRunLive: Bool
        var liveSubagents: Int
        var activityAt: Date
        var state: AgentState = .idle
    }

    private static let activeRunStatuses = "('preparing','starting','running','waiting')"

    private static let candidatesSQL = """
    SELECT
      t.thread_id,
      t.updated_at,
      t.created_at,
      CASE WHEN json_valid(t.payload_json) THEN json_extract(t.payload_json, '$.lineage.relationshipToParent') END,
      CASE WHEN json_valid(t.payload_json) THEN json_extract(t.payload_json, '$.lineage.parentThreadId') END,
      (SELECT r.status FROM orchestration_v2_projection_runs r
         WHERE r.thread_id = t.thread_id AND r.status IN \(activeRunStatuses)
         ORDER BY r.ordinal DESC LIMIT 1),
      (SELECT r.status FROM orchestration_v2_projection_runs r
         WHERE r.thread_id = t.thread_id
           AND r.status <> 'rolled_back'
           AND NOT (r.status = 'queued' AND json_extract(r.payload_json, '$.queueHeld') IS 1)
           AND NOT (r.status = 'cancelled' AND json_extract(r.payload_json, '$.startedAt') IS NULL)
         ORDER BY r.ordinal DESC LIMIT 1),
      (SELECT MAX(COALESCE(r.completed_at, json_extract(r.payload_json, '$.startedAt'), r.requested_at))
         FROM orchestration_v2_projection_runs r WHERE r.thread_id = t.thread_id),
      (SELECT MAX(m.created_at) FROM orchestration_v2_projection_messages m WHERE m.thread_id = t.thread_id),
      (SELECT i.updated_at FROM orchestration_v2_projection_turn_items i
         WHERE i.thread_id = t.thread_id ORDER BY i.ordinal DESC LIMIT 1),
      EXISTS (SELECT 1 FROM orchestration_v2_projection_runtime_requests q
         WHERE q.thread_id = t.thread_id AND q.status = 'pending'),
      EXISTS (SELECT 1 FROM orchestration_v2_projection_runs r
         JOIN orchestration_v2_projection_turn_items si ON si.thread_id = r.thread_id AND si.run_id = r.run_id
         WHERE r.thread_id = t.thread_id AND r.status IN \(activeRunStatuses)
           AND si.type = 'secret_request' AND si.status = 'waiting'),
      EXISTS (SELECT 1 FROM orchestration_v2_projection_turn_items li
         WHERE li.thread_id = t.thread_id AND li.type = 'link_request' AND li.status = 'waiting'
           AND NOT EXISTS (SELECT 1 FROM orchestration_v2_projection_messages um
             WHERE um.thread_id = li.thread_id AND um.role = 'user'
               AND json_extract(um.payload_json, '$.createdBy') = 'user'
               AND julianday(um.updated_at) >
                   julianday(COALESCE(json_extract(li.payload_json, '$.startedAt'), li.updated_at)))),
      own.status,
      own.updated_at,
      EXISTS (SELECT 1 FROM orchestration_v2_projection_runs pr
         WHERE pr.run_id = own.run_id AND pr.status IN \(activeRunStatuses)),
      (SELECT COUNT(*) FROM orchestration_v2_projection_subagents s
         WHERE s.thread_id = t.thread_id AND s.status IN ('pending','running','waiting')
           AND (EXISTS (SELECT 1 FROM orchestration_v2_projection_runs pr
                  WHERE pr.run_id = s.run_id AND pr.status IN \(activeRunStatuses))
                OR EXISTS (SELECT 1 FROM orchestration_v2_projection_runs cr
                  WHERE cr.thread_id = s.child_thread_id AND cr.status IN \(activeRunStatuses))))
    FROM orchestration_v2_projection_threads t
    LEFT JOIN orchestration_v2_projection_subagents own ON own.subagent_id = (
      SELECT s.subagent_id FROM orchestration_v2_projection_subagents s
      WHERE s.child_thread_id = t.thread_id ORDER BY s.updated_at DESC LIMIT 1)
    WHERE t.archived_at IS NULL AND t.deleted_at IS NULL
    """

    private func loadCandidates(_ db: T3SQLiteConnection) throws -> [Candidate] {
        var result: [Candidate] = []
        try db.query(Self.candidatesSQL) { row in
            guard let id = row.string(0) else { return }
            let updatedAt = date(row.string(1))
            let createdAt = date(row.string(2))
            let ownSubagentUpdatedAt = date(row.string(14))
            // Activity = newest of run start/finish, message, latest turn item, subagent progress.
            let activity = [date(row.string(7)), date(row.string(8)), date(row.string(9)), ownSubagentUpdatedAt]
                .compactMap { $0 }
                .max() ?? updatedAt ?? createdAt ?? .distantPast
            result.append(Candidate(
                id: id,
                updatedAt: updatedAt,
                isSubagent: row.string(3) == "subagent",
                parentId: row.string(4),
                activeRunStatus: row.string(5),
                latestRunStatus: row.string(6),
                hasPendingRequest: row.bool(10),
                hasPendingSecret: row.bool(11),
                hasPendingLink: row.bool(12),
                ownSubagentStatus: row.string(13),
                ownSubagentRunLive: row.bool(15),
                liveSubagents: row.int(16),
                activityAt: activity
            ))
        }
        return result
    }

    /// Fills `state` for every candidate. Returns parentId -> childId for parents whose
    /// needsInput comes from a subagent (so the summary is read from the child).
    private func resolveStates(_ candidates: inout [Candidate]) -> [String: String] {
        for index in candidates.indices {
            candidates[index].state = Self.baseState(candidates[index])
        }
        var indexById: [String: Int] = [:]
        for (index, candidate) in candidates.enumerated() { indexById[candidate.id] = index }

        var pendingSource: [String: String] = [:]
        for child in candidates where child.isSubagent && child.state == .needsInput {
            guard let parentId = child.parentId, let parentIndex = indexById[parentId],
                  candidates[parentIndex].state != .needsInput else { continue }
            candidates[parentIndex].state = .needsInput
            pendingSource[parentId] = child.id
        }
        for index in candidates.indices
        where candidates[index].liveSubagents > 0
            && candidates[index].state != .running
            && candidates[index].state != .needsInput {
            candidates[index].state = .running
        }
        return pendingSource
    }

    private func resolveOfflineStates(_ candidates: inout [Candidate]) -> [String: String] {
        for index in candidates.indices {
            let state = candidates[index].latestRunStatus.map(Self.runState) ?? .idle
            candidates[index].state = state == .running ? .idle : state
            candidates[index].liveSubagents = 0
        }
        return [:]
    }

    private static func baseState(_ c: Candidate) -> AgentState {
        if c.hasPendingRequest || c.hasPendingSecret || c.hasPendingLink { return .needsInput }
        if c.activeRunStatus != nil { return .running }
        if let status = c.latestRunStatus { return runState(status) }
        if c.isSubagent, let status = c.ownSubagentStatus {
            switch status {
            case "pending", "running", "waiting":
                // Guard against stale rows: the owning run must still be live.
                return c.ownSubagentRunLive ? .running : .idle
            case "completed": return .completed
            case "failed", "interrupted", "cancelled": return .failed
            default: return .idle
            }
        }
        return .idle
    }

    static func runState(_ status: String) -> AgentState {
        switch status {
        case "preparing", "queued", "starting", "running", "waiting": return .running
        case "completed": return .completed
        case "failed", "interrupted", "cancelled": return .failed
        default: return .idle // rolled_back / unknown future values
        }
    }

    /// Finished threads count as fresh "Done" (shown above running ones) for this long.
    static let freshDoneWindow: TimeInterval = 30 * 60

    /// Display order: needs input → freshly done/failed → running → older finished / idle.
    private static func stateRank(_ state: AgentState, _ at: Date) -> Int {
        switch state {
        case .needsInput: return 0
        case .completed, .failed:
            return Date().timeIntervalSince(at) <= freshDoneWindow ? 1 : 3
        case .running: return 2
        case .idle: return 3
        }
    }

    private static func displayOrder(_ a: Candidate, _ b: Candidate) -> Bool {
        let ra = stateRank(a.state, a.activityAt), rb = stateRank(b.state, b.activityAt)
        if ra != rb { return ra < rb }
        if a.activityAt != b.activityAt { return a.activityAt > b.activityAt }
        return a.id < b.id
    }

    private static func displayOrder(_ a: AgentThread, _ b: AgentThread) -> Bool {
        let ra = stateRank(a.state, a.updatedAt), rb = stateRank(b.state, b.updatedAt)
        if ra != rb { return ra < rb }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.id < b.id
    }

    // MARK: - Phase 2: details for the (at most 10) selected threads

    private static let detailSQL = """
    SELECT
      t.title,
      t.default_provider,
      p.title,
      CASE WHEN json_valid(t.payload_json) THEN json_extract(t.payload_json, '$.modelSelection.model') END,
      (SELECT pt.driver FROM orchestration_v2_projection_provider_threads pt
         WHERE pt.thread_id = t.thread_id AND pt.driver IS NOT NULL ORDER BY pt.updated_at DESC LIMIT 1),
      (SELECT json_extract(tu.payload_json, '$.model') FROM orchestration_v2_projection_provider_turns tu
         WHERE tu.thread_id = t.thread_id ORDER BY tu.started_at DESC LIMIT 1)
    FROM orchestration_v2_projection_threads t
    LEFT JOIN projection_projects p ON p.project_id = t.project_id
    WHERE t.thread_id = ?1
    """

    /// The active run if any, otherwise the latest presentable run.
    private static let runSQL = """
    SELECT
      COALESCE(json_extract(r.payload_json, '$.workStartedAt'), json_extract(r.payload_json, '$.startedAt'), r.requested_at),
      json_extract(r.payload_json, '$.modelSelection.model'),
      COALESCE(r.completed_at, json_extract(r.payload_json, '$.startedAt'), r.requested_at)
    FROM orchestration_v2_projection_runs r
    WHERE r.thread_id = ?1
      AND r.status <> 'rolled_back'
      AND NOT (r.status = 'queued' AND json_extract(r.payload_json, '$.queueHeld') IS 1)
      AND NOT (r.status = 'cancelled' AND json_extract(r.payload_json, '$.startedAt') IS NULL)
    ORDER BY (r.status IN \(activeRunStatuses)) DESC, r.ordinal DESC
    LIMIT 1
    """

    private static let subagentSQL = """
    SELECT s.driver, s.started_at, json_extract(s.payload_json, '$.progress'),
      COALESCE(json_extract(s.payload_json, '$.model'), json_extract(s.payload_json, '$.modelSelection.model'))
    FROM orchestration_v2_projection_subagents s
    WHERE s.child_thread_id = ?1
    ORDER BY s.updated_at DESC
    LIMIT 1
    """

    /// Latest assistant text, or user text the user actually typed (not agent prompts / notifications).
    private static let messageSQL = """
    SELECT m.role, substr(json_extract(m.payload_json, '$.text'), 1, 1200), m.updated_at
    FROM orchestration_v2_projection_messages m
    WHERE m.thread_id = ?1
      AND (m.role = 'assistant'
           OR (m.role = 'user' AND COALESCE(json_extract(m.payload_json, '$.createdBy'), 'user') = 'user'))
      AND length(trim(COALESCE(json_extract(m.payload_json, '$.text'), ''))) > 0
    ORDER BY m.created_at DESC, m.message_id DESC
    LIMIT 1
    """

    /// Most relevant open request: approvals first, then the newest question / secret / link card.
    private static let pendingSQL = """
    SELECT kind, a, b, c, d FROM (
      SELECT 0 AS prio, q.created_at AS at, q.kind AS kind,
        json_extract(i.payload_json, '$.prompt') AS a,
        json_extract(i.payload_json, '$.reason') AS b,
        json_extract(i.payload_json, '$.questions[0].question') AS c,
        json_extract(i.payload_json, '$.questions[0].header') AS d
      FROM orchestration_v2_projection_runtime_requests q
      LEFT JOIN orchestration_v2_projection_turn_items i
        ON i.node_id = q.node_id AND i.thread_id = q.thread_id
       AND i.type IN ('approval_request', 'user_input_request')
       AND json_extract(i.payload_json, '$.requestId') = q.runtime_request_id
      WHERE q.thread_id = ?1 AND q.status = 'pending'
      UNION ALL
      SELECT 1, si.updated_at, 'secret_request',
        json_extract(si.payload_json, '$.label'), json_extract(si.payload_json, '$.reason'), NULL, NULL
      FROM orchestration_v2_projection_runs r
      JOIN orchestration_v2_projection_turn_items si ON si.thread_id = r.thread_id AND si.run_id = r.run_id
      WHERE r.thread_id = ?1 AND r.status IN \(activeRunStatuses)
        AND si.type = 'secret_request' AND si.status = 'waiting'
      UNION ALL
      SELECT 1, li.updated_at, 'link_request',
        COALESCE(json_extract(li.payload_json, '$.label'), json_extract(li.payload_json, '$.url')),
        json_extract(li.payload_json, '$.reason'), NULL, NULL
      FROM orchestration_v2_projection_turn_items li
      WHERE li.thread_id = ?1 AND li.type = 'link_request' AND li.status = 'waiting'
        AND NOT EXISTS (SELECT 1 FROM orchestration_v2_projection_messages um
          WHERE um.thread_id = li.thread_id AND um.role = 'user'
            AND json_extract(um.payload_json, '$.createdBy') = 'user'
            AND julianday(um.updated_at) >
                julianday(COALESCE(json_extract(li.payload_json, '$.startedAt'), li.updated_at)))
    )
    ORDER BY CASE WHEN prio = 0 AND kind <> 'user_input' THEN 0 ELSE 1 END, at DESC
    LIMIT 1
    """

    private func loadThread(_ db: T3SQLiteConnection, _ c: Candidate, pendingSourceId: String?) throws -> AgentThread {
        var title = ""
        var provider = ""
        var projectName: String?
        var threadModel: String?
        var driver: String?
        var turnModel: String?
        try db.query(Self.detailSQL, [c.id]) { row in
            title = row.string(0) ?? ""
            provider = row.string(1) ?? ""
            projectName = row.string(2)
            threadModel = row.string(3)
            driver = row.string(4)
            turnModel = row.string(5)
        }

        var runStartedAt: Date?
        var runModel: String?
        var runActivityAt: Date?
        try db.query(Self.runSQL, [c.id]) { row in
            runStartedAt = date(row.string(0))
            runModel = row.string(1)
            runActivityAt = date(row.string(2))
        }

        var subagentProgress: String?
        var subagentModel: String?
        if c.isSubagent {
            try db.query(Self.subagentSQL, [c.id]) { row in
                if driver == nil { driver = row.string(0) }
                if runStartedAt == nil { runStartedAt = date(row.string(1)) }
                subagentProgress = row.string(2)
                subagentModel = row.string(3)
            }
        }

        var messageText: String?
        var messageAt: Date?
        try db.query(Self.messageSQL, [c.id]) { row in
            messageText = row.string(1)
            messageAt = date(row.string(2))
        }

        var preview: String?
        if c.isSubagent, c.state == .running || c.state == .needsInput, let progress = subagentProgress {
            preview = T3Text.preview(progress, limit: Self.previewLimit)
        }
        if preview == nil, let messageText {
            preview = T3Text.preview(messageText, limit: Self.previewLimit)
        }

        var pendingSummary: String?
        if c.state == .needsInput {
            pendingSummary = try loadPendingSummary(db, threadId: c.id)
            if pendingSummary == nil, let childId = pendingSourceId {
                pendingSummary = try loadPendingSummary(db, threadId: childId).map { "Subagent: " + $0 }
            }
            if pendingSummary == nil { pendingSummary = "Waiting for your input" }
        }

        let updatedAt = [c.activityAt, runActivityAt, messageAt].compactMap { $0 }.max() ?? c.activityAt
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        return AgentThread(
            id: c.id,
            title: trimmedTitle.isEmpty ? "Untitled thread" : trimmedTitle,
            provider: driver ?? (provider.isEmpty ? "unknown" : provider),
            model: Self.firstNonEmpty(turnModel, runModel, subagentModel, threadModel),
            projectName: Self.displayProjectName(projectName),
            state: c.state,
            updatedAt: updatedAt,
            runStartedAt: runStartedAt,
            lastMessagePreview: preview,
            pendingRequestSummary: pendingSummary,
            subagentCount: c.liveSubagents,
            isSubagent: c.isSubagent
        )
    }

    private func loadPendingSummary(_ db: T3SQLiteConnection, threadId: String) throws -> String? {
        var summary: String?
        try db.query(Self.pendingSQL, [threadId]) { row in
            summary = Self.pendingSummary(
                kind: row.string(0) ?? "",
                a: row.string(1),
                b: row.string(2),
                question: row.string(3),
                header: row.string(4)
            )
        }
        return summary
    }

    static func pendingSummary(kind: String, a: String?, b: String?, question: String?, header: String?) -> String {
        func clean(_ text: String?) -> String? {
            text.flatMap { T3Text.preview($0, limit: 110) }
        }
        let detail = clean(a) ?? clean(b)
        let text: String
        switch kind {
        case "command": text = detail.map { "Approve command: \($0)" } ?? "Approve a command"
        case "file-change": text = detail.map { "Approve edit: \($0)" } ?? "Approve file changes"
        case "file-read": text = detail.map { "Approve read: \($0)" } ?? "Approve file read"
        case "permission": text = detail.map { "Approve: \($0)" } ?? "Permission requested"
        case "mcp-elicitation": text = detail.map { "MCP input: \($0)" } ?? "MCP server needs input"
        case "user_input":
            if let q = clean(question) ?? clean(header) {
                text = "Question: \(q)"
            } else {
                text = "Agent asked a question"
            }
        case "dynamic_tool_call": text = "Tool call waiting for a response"
        case "auth_refresh": text = "Sign-in required"
        case "secret_request": text = clean(a).map { "Secret requested: \($0)" } ?? "Secret requested"
        case "link_request": text = (clean(a) ?? clean(b)).map { "Link environment: \($0)" } ?? "Link an environment"
        default: text = detail.map { "Input needed: \($0)" } ?? "Waiting for your input"
        }
        return T3Text.preview(text, limit: previewLimit) ?? text
    }

    // MARK: - Helpers

    /// T3 files project-less threads under an auto-created scratch project titled "No project".
    private static func displayProjectName(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title != "No project" else { return nil }
        return title
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value, !value.trimmingCharacters(in: .whitespaces).isEmpty { return value }
        }
        return nil
    }

    func date(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }
}

// MARK: - Preview text

enum T3Text {
    private static let imageRegex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\([^)]*\)"#)
    private static let linkRegex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]*\)"#)
    private static let linePrefixRegex = try? NSRegularExpression(
        pattern: #"(?m)^[ \t]*(?:#{1,6}[ \t]+|>[ \t]?|[-*+][ \t]+\[[ xX]\][ \t]+|[-*+][ \t]+|\d{1,3}[.)][ \t]+)"#)
    private static let fenceRegex = try? NSRegularExpression(pattern: #"(?m)^[ \t]*(```|~~~)[^\n]*$"#)
    private static let ruleRegex = try? NSRegularExpression(pattern: #"(?m)^[ \t]*([-*_][ \t]*){3,}$"#)
    private static let emphasisRegex = try? NSRegularExpression(pattern: #"(\*\*|__|~~|`+)"#)
    private static let singleEmphasisRegex = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])[*_](?=\S)(.+?)(?<=\S)[*_](?![\p{L}\p{N}])"#)
    private static let whitespaceRegex = try? NSRegularExpression(pattern: #"\s+"#)

    private static let attachmentPlaceholder =
        "[User attached one or more files without additional text. Respond using the conversation context and the attached files.]"

    /// Single line, whitespace collapsed, rough markdown stripped, at most `limit` characters.
    static func preview(_ raw: String, limit: Int) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if text == attachmentPlaceholder { return "(attached files)" }
        if text.lowercased().hasPrefix("ultrathink:") {
            text = String(text.dropFirst("ultrathink:".count))
        }
        text = replace(fenceRegex, in: text, with: " ")
        text = replace(ruleRegex, in: text, with: " ")
        text = replace(imageRegex, in: text, with: "$1")
        text = replace(linkRegex, in: text, with: "$1")
        text = replace(linePrefixRegex, in: text, with: "")
        text = replace(emphasisRegex, in: text, with: "")
        text = replace(singleEmphasisRegex, in: text, with: "$1")
        text = replace(whitespaceRegex, in: text, with: " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        return truncate(text, limit: limit)
    }

    static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        var cut = String(text.prefix(limit - 1))
        // Prefer a word boundary if it doesn't lose too much.
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit * 3 / 4 {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func replace(_ regex: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let regex else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
