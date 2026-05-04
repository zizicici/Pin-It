//
//  CloudKitClient.swift
//  Pin It
//
//  Created by OpenAI on 2026/5/4.
//

import CloudKit

protocol CloudKitDatabaseClient {
    var database: CKDatabase { get }

    func accountStatus() async throws -> CKAccountStatus
    func add(_ operation: CKDatabaseOperation)
}

final class LiveCloudKitDatabaseClient: CloudKitDatabaseClient {
    private let container: CKContainer

    init(containerIdentifier: String = cloudKitContainerIdentifier) {
        container = CKContainer(identifier: containerIdentifier)
    }

    var database: CKDatabase {
        container.privateCloudDatabase
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKAccountStatus, Error>) in
            container.accountStatus { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
    }

    func add(_ operation: CKDatabaseOperation) {
        database.add(operation)
    }
}
