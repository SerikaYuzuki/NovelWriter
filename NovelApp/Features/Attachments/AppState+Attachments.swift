import AppKit
import EditorKit
import Foundation
import NovelCore
import NovelSync

extension AppState {
    // MARK: - 資料添付

    /// 現在のリポジトリが資料添付に対応しているか。
    var supportsAttachments: Bool {
        attachmentManager != nil
    }

    /// 資料一覧を保存層から再読み込みする。
    func reloadAttachments(expectedSession: DocumentSessionToken? = nil) async {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: ()) {
            let packageURL = documentURL
            attachments = await saveCoordinator.performExclusive {
                await loadAttachments(for: packageURL)
            }
        }
    }

    /// 外部ファイルを現在の作品へ資料として取り込む。
    ///
    /// 添付ファイルのコピーは大きなファイルだと数秒かかることがあり、その間に
    /// 本文編集のデバウンス保存(2秒)が発火すると、保存側は「取り込み中の古い
    /// attachments/ をコピーした作業ディレクトリ」でパッケージを全置換してしまい、
    /// 取り込んだ資料が失われる(Phase 4 レビュー F-A)。そこで、まず
    /// `saveCoordinator.saveNow()` で保留中の編集を先に排出したうえで、実際の
    /// ファイルコピーと一覧再読込みは `saveCoordinator.performExclusive` の中で
    /// 行い、その間は新しい保存が一切始まらないようにする。
    ///
    /// - Important: `saveNow()` は `performExclusive` の *外側* で呼ぶこと。
    ///   `performExclusive` の中から `saveNow()` を呼ぶと、排他区間そのものを
    ///   待つ形になりデッドロックする。
    @discardableResult
    func addAttachment(
        from sourceURL: URL,
        expectedSession: DocumentSessionToken? = nil
    ) async -> Attachment? {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: nil) {
            await addAttachmentSerially(from: sourceURL)
        }
    }

    private func addAttachmentSerially(from sourceURL: URL) async -> Attachment? {
        guard let attachmentManager else { return nil }
        guard await saveCoordinator.saveNow() else { return nil }
        let packageURL = documentURL

        return await saveCoordinator.performExclusive {
            do {
                let attachment = try await attachmentManager.addAttachment(from: sourceURL, to: packageURL)
                attachments = await loadAttachments(for: packageURL)
                return attachment
            } catch {
                print("[FUMINIWA] 資料の取り込みに失敗しました(\(Self.errorCategory(error)))")
                return nil
            }
        }
    }

    /// 作品から資料を削除する。添付操作と保存の直列化は `addAttachment` と同じ理由
    /// (Phase 4 レビュー F-A)。
    func deleteAttachment(
        _ attachment: Attachment,
        expectedSession: DocumentSessionToken? = nil
    ) async -> Bool {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: false) {
            await deleteAttachmentSerially(attachment)
        }
    }

    private func deleteAttachmentSerially(_ attachment: Attachment) async -> Bool {
        guard let attachmentManager else { return false }
        guard await saveCoordinator.saveNow() else { return false }
        let packageURL = documentURL

        return await saveCoordinator.performExclusive {
            do {
                try await attachmentManager.deleteAttachment(named: attachment.fileName, from: packageURL)
                attachments = await loadAttachments(for: packageURL)
                return true
            } catch {
                print("[FUMINIWA] 資料の削除に失敗しました(\(attachment.fileName), \(Self.errorCategory(error)))")
                return false
            }
        }
    }

    /// プレビュー用の資料URLを返す。
    func attachmentPreviewURL(for attachment: Attachment) -> URL? {
        attachmentManager?.attachmentURL(named: attachment.fileName, in: documentURL)
    }
}
