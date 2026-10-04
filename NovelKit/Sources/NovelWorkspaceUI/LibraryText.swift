/// Shared shelf wording. Recovery instructions retain the host's actual controls.
public enum LibraryText {
    public static let search = "作品を検索"
    public static let loading = "作品一覧を読み込み中…"
    public static let offline = "オフラインです"
    public static let loadFailed = "作品一覧を読み込めませんでした"
    public static let empty = "最初の作品を書きましょう"
    public static let emptyMac = "オフラインでも作成・編集できます。"
    public static let emptyIOS = "「新規作品」から、サインインせずに書き始められます。"
    public static let retryMac = "「更新」からもう一度読み込めます。端末内では「新規」から書き始められます。"
    public static let retryIOS = "下に引いて再読み込みできます。「新規作品」から端末内で書き始められます。"
    public static let noSearchResults = "作品が見つかりません"
    public static let searchHint = "検索する言葉を変えてください。"
    public static let noSearchResultsNotice = noSearchResults + "。" + searchHint
    public static let loadMore = "サーバーの作品をさらに読み込む"
    public static let importWork = "作品を取り込む…"
    public static let rename = "作品名を変更"
    public static let title = "作品名"
    public static let change = "変更"
    public static let renameFailed = "作品名を変更できませんでした"
    public static let renameRetry = "作品やアカウントが切り替わっていないか、接続状態を確認して再試行してください。"
    public static let deleteConfirmation = "作品を完全に削除しますか？"
    public static let delete = "削除"
    public static let cancel = "キャンセル"
    public static let cancelImportConfirmation = "取り込みを中止して開きますか？"
    public static let cancelImportAndOpen = "取り込みを中止して開く"
    public static let pendingDeletion = "削除待ち・接続時に再試行"

    public static func deletionMessage(title: String) -> String {
        "「\(title)」を一覧から削除します。同期した作品のサーバー受領済みデータは1年間保管されます。この端末だけの作品は元に戻せません。"
    }
}
