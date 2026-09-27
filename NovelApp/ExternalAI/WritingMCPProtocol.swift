#if os(macOS)
import Foundation
import NovelCore
import NovelWritingSupport

@MainActor
enum WritingMCPProtocol {
    static func respond(_ data: Data, host: WritingAssistantHost?) async -> Data? {
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid request"]])
        }
        guard let id = request["id"] else { return nil }
        let parameters = request["params"] as? [String: Any] ?? [:]
        var result: [String: Any]
        switch method {
        case "initialize":
            let requested = parameters["protocolVersion"] as? String ?? ""
            result = ["protocolVersion": ["2025-03-26", "2025-06-18", "2025-11-25"].contains(requested) ? requested : "2025-11-25",
                      "capabilities": ["tools": ["listChanged": false]], "serverInfo": ["name": "FUMINIWA", "version": "1.0"],
                      "instructions": "登録した接続を信頼しています。ユーザーが指定した範囲だけをscope.pathsに変換してください。編集前にread_workで現在のworkId、sessionId、対象値を確認してください。権限は各依頼だけ有効です。"]
        case "ping": result = [:]
        case "tools/list": result = ["tools": tools]
        case "tools/call":
            do {
                guard !Task.isCancelled, let host else { throw WritingError.changedScope }
                let name = parameters["name"] as? String ?? ""
                let arguments = parameters["arguments"] as? [String: Any] ?? [:]
                let capture = try await host.captureWhenReady()
                switch name {
                case "read_work":
                    var output: [String: Any] = ["workId": capture.workId.uuidString.lowercased(), "sessionId": host.contextID]
                    let value = try WritingValue.document(capture.document)
                    if let paths = arguments["paths"] as? [[String]], !paths.isEmpty {
                        output["values"] = try paths.map { path in
                            guard WritingGrant.wholeWork.permits(path) else { throw WritingError.outsideGrant }
                            if path.first == "attachments" {
                                guard path.count == 2, let id = UUID(uuidString: path[1]),
                                      let file = capture.attachments.first(where: { $0.id == id }),
                                      file.bytes.count <= 300_000 else { throw WritingError.invalidEdit }
                                return try ["path": path, "value": json(file) ?? NSNull()] as [String: Any]
                            }
                            return try ["path": path, "value": json(value.at(path)) ?? NSNull()] as [String: Any]
                        }
                    } else {
                        output["document"] = try json(capture.document)
                    }
                    output["attachments"] = capture.attachments.map { [
                        "id": $0.id.uuidString.lowercased(),
                        "fileName": $0.fileName,
                        "byteCount": $0.bytes.count
                    ] as [String: Any] }
                    output["templates"] = try templates()
                    result = try content(output)
                case "edit_work":
                    try requireContext(arguments, capture: capture, host: host)
                    guard let editID = (arguments["requestId"] as? String).flatMap(UUID.init(uuidString:)),
                          let scope = arguments["scope"], let changes = arguments["changes"] else { throw WritingError.invalidEdit }
                    let grant = try JSONDecoder().decode(WritingGrant.self, from: JSONSerialization.data(withJSONObject: scope))
                    let edits = try JSONDecoder().decode([WritingChange].self, from: JSONSerialization.data(withJSONObject: changes))
                    let edit = WritingEdit(id: editID, workId: capture.workId, documentId: capture.document.id, changes: edits)
                    if let state = try await host.editOutcome(edit) {
                        result = try content(["applied": state == "applied", "state": state,
                                              "replayed": true, "requestId": editID.uuidString.lowercased()])
                        break
                    }
                    try await host.append(WritingRecord(
                        id: edit.id,
                        workId: capture.workId,
                        kind: "edit",
                        key: editID.uuidString.lowercased(),
                        payload: WritingRecord.payload(edit)
                    ))
                    try await host.apply(edit, grant)
                    result = try content(["applied": true, "requestId": editID.uuidString.lowercased()])
                case "undo_edit":
                    try requireContext(arguments, capture: capture, host: host)
                    guard let editID = (arguments["requestId"] as? String).flatMap(UUID.init(uuidString:)) else { throw WritingError.invalidEdit }
                    try await host.undo(editID); result = try content(["undone": true])
                default: throw WritingError.invalidEdit
                }
            } catch { result = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true] }
        default: return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
        }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func requireContext(_ arguments: [String: Any], capture: WritingCapture, host: WritingAssistantHost) throws {
        guard arguments["sessionId"] as? String == host.contextID,
              (arguments["workId"] as? String)?.lowercased() == capture.workId.uuidString.lowercased() else { throw WritingError.changedScope }
    }

    private static func encode(_ value: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static func json(_ value: some Encodable) throws -> Any? {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }

    private static func content(_ value: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= 16_000_000 else { throw AssistantError.tooLarge }
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": false]
    }

    static func templates() throws -> [String: Any] {
        try ["chapter": json(Chapter(title: "新しい章", episodes: []))!, "episode": json(Episode(title: "新しい話"))!,
             "character": json(Character(name: "名前"))!, "plotCard": json(PlotCard(title: "プロット"))!,
             "flag": json(Flag(title: "伏線"))!, "worldNote": json(WorldNote(title: "資料・設定"))!]
    }

    private static var tools: [[String: Any]] {
        let path: [String: Any] = ["type": "array", "items": ["type": "string"]]
        let context: [String: Any] = ["workId": ["type": "string"], "sessionId": ["type": "string"], "requestId": ["type": "string"]]
        return [
            ["name": "read_work", "description": "現在開いている作品を読む。pathsでフィールドを絞れる。配列はUUIDで指定。構成、人物、プロット、伏線、メモ、資料ノートと作成用テンプレートを返す。",
             "inputSchema": ["type": "object", "properties": ["paths": ["type": "array", "items": path]], "additionalProperties": false],
             "annotations": ["readOnlyHint": true, "openWorldHint": false]],
            [
                "name": "edit_work",
                "description": "ユーザーが今回指定した範囲だけを編集。scope.pathsは許可するパスの接頭辞。beforeに読取値、afterに新値。追加before:null、削除after:null。追加/削除は項目UUIDのパス、配列全体は同じ項目の並べ替えのみ。"
                    +
                    "添付資料はattachments/UUID、値は{id,fileName,bytes:base64}で1件300KB以内。attachmentsの並べ替え値はUUID配列。appendOnlyは本文末尾追記。requestIdはUUID。再送時も同じID。",
                "inputSchema": ["type": "object", "properties": context.merging([
                    "scope": [
                        "type": "object",
                        "properties": ["paths": ["type": "array", "items": path], "appendOnly": ["type": "boolean"]],
                        "required": ["paths", "appendOnly"],
                        "additionalProperties": false
                    ],
                    "changes": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": ["path": path, "before": [:], "after": [:]],
                            "required": ["path", "before", "after"],
                            "additionalProperties": false
                        ]
                    ]
                ]) { _, new in new }, "required": ["workId", "sessionId", "requestId", "scope", "changes"], "additionalProperties": false],
                "annotations": ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": false]
            ],
            ["name": "undo_edit", "description": "同じ作品の依頼1回分を取り消す。その後に同じ対象が変わっていれば拒否する。",
             "inputSchema": [
                 "type": "object",
                 "properties": context,
                 "required": ["workId", "sessionId", "requestId"],
                 "additionalProperties": false
             ],
             "annotations": ["readOnlyHint": false, "destructiveHint": true, "openWorldHint": false]]
        ]
    }
}
#endif
