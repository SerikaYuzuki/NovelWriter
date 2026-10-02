import Foundation
import NovelCore
import NovelSyncV2

/// Mutations participate in the caller-owned Store transaction; no transaction is opened here.
extension WorkRepository {
    func replacePortableResources(
        workID: WorkID,
        resources: [PortableResource]
    ) throws {
        let ordered = try validatedPortableResources(resources)
        try exec(
            "DELETE FROM work_resources WHERE work_id=?",
            [.text(workID.description)]
        )
        for resource in ordered {
            let componentsJSON = try encodePathComponents(resource.pathComponents)
            let originalPath = resource.pathComponents.joined(separator: "/")
            switch resource.kind {
            case .directory:
                guard resource.bytes == nil else {
                    throw SyncV2StoreError.invalidSnapshot
                }
                try exec(
                    """
                    INSERT INTO work_resources(
                      work_id,path_components,kind,original_path,object_id,byte_count
                    ) VALUES(?,?,?,?,NULL,0)
                    """,
                    [
                        .text(workID.description), .text(componentsJSON),
                        .text(resource.kind.rawValue), .text(originalPath)
                    ]
                )
            case .regularFile:
                guard let bytes = resource.bytes else {
                    throw SyncV2StoreError.invalidSnapshot
                }
                let objectID = ObjectID(data: bytes)
                try upsertPortableResourceObject(objectID: objectID, bytes: bytes)
                try exec(
                    """
                    INSERT INTO work_resources(
                      work_id,path_components,kind,original_path,object_id,byte_count
                    ) VALUES(?,?,?,?,?,?)
                    """,
                    [
                        .text(workID.description), .text(componentsJSON),
                        .text(resource.kind.rawValue), .text(originalPath),
                        .blob(objectID.bytes), .int(Int64(bytes.count))
                    ]
                )
                try exec(
                    "UPDATE resources SET gc_root=1 WHERE object_id=?",
                    [.blob(objectID.bytes)]
                )
            }
        }
        try recomputeResourceRoots()
    }

    func copyPortableResources(from sourceWorkID: WorkID, to destinationWorkID: WorkID) throws {
        let resources = try loadPortableResources(workID: sourceWorkID)
        try replacePortableResources(workID: destinationWorkID, resources: resources)
    }

    func loadPortableResources(workID: WorkID) throws -> [PortableResource] {
        let rows = try queryRows(
            WorkResourceRow.self,
            """
            SELECT \(WorkResourceRow.columns)
            FROM work_resources WHERE work_id=?
            ORDER BY original_path COLLATE BINARY, kind COLLATE BINARY
            """,
            [.text(workID.description)]
        )
        return try rows.map { row in
            guard let pathJSON = row.pathComponents,
                  let kindText = row.kind,
                  let kind = PortableResource.Kind(rawValue: kindText),
                  let path = try? decodePathComponents(pathJSON) else {
                throw SyncV2StoreError.invalidSnapshot
            }
            switch kind {
            case .directory:
                guard row.objectID == nil, row.byteCount == 0 else {
                    throw SyncV2StoreError.invalidSnapshot
                }
                return PortableResource(pathComponents: path, kind: kind)
            case .regularFile:
                guard let objectID = row.objectID,
                      let byteCount = row.byteCount,
                      let bytes = try queryRows(
                          ResourceBytesRow.self,
                          "SELECT \(ResourceBytesRow.columns) FROM resources WHERE object_id=?",
                          [.blob(objectID)]
                      ).first,
                      let data = bytes.bytes,
                      bytes.byteCount == byteCount,
                      ObjectID(data: data).bytes == objectID else {
                    throw SyncV2StoreError.invalidSnapshot
                }
                return PortableResource(pathComponents: path, kind: kind, bytes: data)
            }
        }
    }

    func portableResourcesEqual(workID: WorkID, resources: [PortableResource]) throws -> Bool {
        let existing = try loadPortableResources(workID: workID)
        let validated = try validatedPortableResources(resources)
        return existing == validated
    }

    func upsertPortableResourceObject(objectID: ObjectID, bytes: Data) throws {
        if let existing = try queryRows(
            ObjectContentRow.self,
            "SELECT \(ObjectContentRow.columns) FROM resources WHERE object_id=?",
            [.blob(objectID.bytes)]
        ).first {
            guard existing.byteCount == Int64(bytes.count), existing.bytes == bytes else {
                throw SyncV2StoreError.invalidSnapshot
            }
            return
        }
        try exec(
            "INSERT INTO resources(object_id,byte_count,bytes,availability,gc_root) VALUES(?,?,?,'available',1)",
            [.blob(objectID.bytes), .int(Int64(bytes.count)), .blob(bytes)]
        )
    }

    func recomputeResourceRoots() throws {
        try exec(
            """
            UPDATE resources SET gc_root=CASE WHEN EXISTS(
              SELECT 1 FROM work_resources wr WHERE wr.object_id=resources.object_id
            ) THEN 1 ELSE 0 END
            """
        )
    }

    func validatedPortableResources(_ resources: [PortableResource]) throws -> [PortableResource] {
        var seen: Set<String> = []
        let sorted = resources.sorted { lhs, rhs in
            let left = lhs.pathComponents.joined(separator: "/")
            let right = rhs.pathComponents.joined(separator: "/")
            if left != right {
                return left.utf8.lexicographicallyPrecedes(right.utf8)
            }
            return lhs.kind.rawValue.utf8.lexicographicallyPrecedes(rhs.kind.rawValue.utf8)
        }
        for resource in sorted {
            guard !resource.pathComponents.isEmpty,
                  resource.pathComponents.count <= 16 else {
                throw SyncV2StoreError.invalidSnapshot
            }
            let originalPath = resource.pathComponents.joined(separator: "/")
            guard originalPath.utf8.count <= 768,
                  originalPath.utf16.count <= 512 else {
                throw SyncV2StoreError.invalidSnapshot
            }
            for component in resource.pathComponents {
                guard !component.isEmpty,
                      component != ".",
                      component != "..",
                      !component.contains("/"),
                      !component.contains("\\"),
                      !component.contains("\0"),
                      component.utf8.count <= 255,
                      component.utf16.count <= 240 else {
                    throw SyncV2StoreError.invalidSnapshot
                }
            }
            let key = resource.pathComponents
                .map { $0.precomposedStringWithCanonicalMapping.lowercased() }
                .joined(separator: "\u{0}")
            guard seen.insert(key).inserted else {
                throw SyncV2StoreError.invalidSnapshot
            }
            if resource.kind == .regularFile {
                guard let bytes = resource.bytes, ObjectID(data: bytes).bytes.count == 32 else {
                    throw SyncV2StoreError.invalidSnapshot
                }
            } else {
                guard resource.bytes == nil else {
                    throw SyncV2StoreError.invalidSnapshot
                }
            }
        }
        return sorted
    }

    func encodePathComponents(_ components: [String]) throws -> String {
        let data = try JSONEncoder().encode(components)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SyncV2StoreError.invalidSnapshot
        }
        return string
    }

    func decodePathComponents(_ value: String) throws -> [String] {
        guard let data = value.data(using: .utf8) else {
            throw SyncV2StoreError.invalidSnapshot
        }
        return try JSONDecoder().decode([String].self, from: data)
    }
}
