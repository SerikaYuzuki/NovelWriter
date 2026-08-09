/// Provider-neutralな実行境界。
///
/// - `start(request:events:)`は明示確認済みrequestだけを受け取る。
/// - 呼び出し側は`AIProviderExecutor`を使い、adapterからstreamを直接生成しない。
/// - Executor/streamがdescriptor一致、raw response文字／byte上限、exact response schema、
///   output budget、typed terminalを検証する。
/// - Adapterは`request.outbound.applicationPrompt`を文字列/byte変換以外で再構築・追記せず、
///   previewにない文脈・metadata・instructionをproviderへ追加しない。
/// - consumer cancel、timeout、budget超過時は`onUpstreamCancellation`から外部処理を止め、
///   孤児通信を残さない。
/// - Adapterの最初の外部副作用より前にcancellation handlerを登録する。handler登録前に
///   subprocessやnetwork送信を開始しない。
/// - SDK固有error、生stderr、pathをstreamへ出さず、必ず`AIError`へ正規化する。
/// - timeoutとoutput budgetはdomain側でもhard limitとして扱う。上流が対応parameterを
///   公開するadapterはrequest値を必ず設定する。公開しない上流では、その欠如をlocal limitで
///   代替したと表現せず、provider disclosureで未保証として扱う。delta累計や完了resultが
///   上限を超えた場合は共通continuationがfail-closedで終了する。
/// - 自動retry・fallbackを行わない。
public protocol AIProvider: Sendable {
    /// Previewとexecutor照合に使う、実行中に変化しないO(1)の不変stored descriptor。
    /// I/O、lock待機、actor hopを行うcomputed getterにしない。
    var descriptor: AIProviderDescriptor { get }

    func start(
        request: AIConfirmedRequest,
        events: AIProviderEventContinuation
    ) async
}
