# Codex Darwin process supervisor 契約

**状態: Checkpoint B2 の合成helper向けnative primitiveを実装 / 実Codex SDK・CLI、network、credential、native manifest verifier、OS-level sandboxは未接続**

本書は、`FUMINIWAExperimental`だけにcompileされるDarwin process supervisorの起動、I/O上限、終了競合、process group cleanupと、その保証外を定める。Swift／Node間のwire契約は[PROTOCOL.md](PROTOCOL.md)、配布rootのcanonical manifestは[MANIFEST.md](MANIFEST.md)、AI全体のGateは[AI_INTEGRATION.md](../../docs/AI_INTEGRATION.md)を正とする。

Checkpoint B2の成功は、実providerへ原稿を送れること、Codex process treeがあらゆる終了でorphan-freeであること、または個人用Experimental Gateを完了したことを意味しない。テストは固定した合成shell helperだけを起動し、実SDK／CLI、API key、network、実原稿を使わない。

B4-Cの`CodexSuspendedProcessIdentityInspector`はB2 transportを実行可能にする拡張ではなく、別のprobe-only primitiveである(D-052)。固定条件でsuspended childを作ってactual identityを観測し、成功時もresumeせずkill／direct reapする。PID／path／FD／capabilityをB2へ引き渡さず、production catalogも空のままである。B4-C timeoutも同期Security API／inspection workerのasync hard return上限ではなく、本書のB2 interactive process lifecycle保証と混同しない。

## 1. 実装境界

- `CodexProcessSupervisor`はactorであり、同じinstance上の実行中sessionを1件に限定する。並行する2件目はspawn前に`alreadyRunning`で拒否する。完了後の同じinstanceによる後続実行は許可される。
- 1 invocationにつき1つのdirect childを`posix_spawn`し、そのPIDをprocess group IDとする新しいprocess groupを作る。shellや`PATH`探索はsupervisor自身では使わない。
- invocationはcanonicalな絶対executable path、canonicalな絶対working directory、argv、明示environment、stdin bytes、request timeout、TERM grace periodを持つ。親environmentは暗黙継承せず、渡されたenvironmentだけを`envp`へ写像する。ただし、許可するenvironment keyのallowlistを組み立てる責務は後続adapterにあり、B2 primitiveだけでは完了しない。
- executableは通常ファイル、実行可能、set-user-ID／set-group-IDなし、group／other writableなしを要求する。executableとworking directoryはいずれもsymlink解決後のcanonical pathと入力pathが一致しなければspawn前に拒否する。この検査はartifact hashやnative manifest検証の代替ではない。
- stdin、stdout、stderrは別pipeとし、親側のwrite/readを同時に進める。macOS 27では`pipe2`をDarwin runtimeから`dlopen`／`dlsym`でprobeし、見つからなければ`pipe2Unavailable`でfail-closedにする。legacy `pipe`へ暗黙fallbackせず、`pipe2(O_CLOEXEC)`、`POSIX_SPAWN_CLOEXEC_DEFAULT`と明示的な`dup2`／`close`により、childへ渡すfile descriptorをstandard streamsへ限定する。このruntime probeの成功を他のOS version／architectureまたは配布runtimeへ一般化しない。
- `POSIX_SPAWN_SETPGROUP`とpgroup `0`でchildをgroup leaderにし、spawn直後に`getpgid(childPID) == childPID`を検査する。signal maskは空にし、変更可能なsignal dispositionはdefaultへ戻す。

このprimitiveはprocess transportだけを担当する。Codex protocol frameのdecode、provider error mapping、Keychain、credential pipe、runtime／manifest attestation、Node environment allowlist、OS-level file access制御を実装しない。

## 2. 固定上限

| 対象 | B2上限 | 挙動 |
| --- | ---: | --- |
| stdin | 512 KiB | ちょうどの値は許可し、1 byteでも超えればspawn前に`standardInputLimitExceeded` |
| stdout | 512 KiB | ちょうどの値は保持可能。超過を観測した時点で`standardOutputLimitExceeded(limit:actualAtLeast:)`をclaimし、先頭512 KiBより多く保持しない |
| stderr | 16 KiB | 内容をresultへ保持せずbyte数だけ数える。超過を観測した時点で`standardErrorLimitExceeded(limit:actualAtLeast:)`をclaimする |
| request timeout | 120秒以下 | 0より大きい値だけを受理し、deadline到達を`timedOut`としてclaimする |
| TERM grace period | 10秒以下 | 0より大きい値だけを受理し、TERM後にlive group memberが残る場合のKILL移行までに使う |

`actualAtLeast`は、上限超過を検出したread時点で少なくとも観測したbyte数であり、childが実際に書こうとした総量ではない。stderr内容をSwiftのresult、domain、UI、通常ログへ保持しないが、pipe read bufferやprocess memoryからsecure eraseしたとは主張しない。stdoutにもprompt／responseが含まれ得るため、後続adapterは生bytesを通常ログへ出してはならない。

この上限はupstream token／費用cap、childのmemory／CPU／process件数、SDK内部record上限の代替ではない。B2ではこれらをまだ強制していない。

## 3. Terminalの線形化

sessionは`exited`、consumer cancel、明示`cancel()`、request timeout、I/O／cap／system-call failureのうち、lock下で最初にclaimされた`stopReason`だけを保持する。遅い自然終了が、すでにclaimされたcancel／timeout／failureを成功へ戻すことはない。`cancel()`は実行中sessionに対して冪等であり、すでにcancel済みのSwift Taskはspawn前に`cancelled`となる。

自然終了を成功候補にできるのは、direct childの終了を`waitid(WEXITED | WNOHANG | WNOWAIT)`で観測し、同じprocess groupにlive memberが観測されない場合だけである。leaderが正常終了してもlive descendantが残っていれば`lingeringDescendant`をclaimし、group cleanup後も成功へ戻さない。

最初の`stopReason`を保つことは、後続の安全検査を無視する意味ではない。pipe drain、direct childのreap、post-reap group probeのいずれかが失敗した場合、supervisorは成功resultを返さずcleanup errorを優先してthrowできる。自然exit codeが非0であること自体はsupervisor層ではprovider failureへ写像せず、`CodexProcessResult.Termination`として上位へ返す。

request timeoutはterminalをclaimするabsolute deadlineである。claim後もprocess group停止、direct child回収、pipe drainをそれぞれ別のbounded cleanup windowで続けるため、`run`の総wall timeは指定request timeoutを超え得る。

## 4. Process group停止と回収証拠

cancel、timeout、cap超過、I/O failure、または`lingeringDescendant`では、次の順序でcleanupする。

1. direct childの終了を`waitid(... WNOWAIT)`で観測しても、まだ`waitpid`せずPID／PGIDのanchorとして保持する。
2. signal可能な同一process-group memberがいれば`kill(-pgid, SIGTERM)`を送り、grace periodまで待つ。
3. live memberが残れば`kill(-pgid, SIGKILL)`を送り、別のbounded cleanup deadlineまで待つ。
4. direct childだけを`waitpid(... WNOHANG)`のbounded loopでreapする。`EINTR`は再試行し、`ECHILD`はownership喪失としてfail-closedにする。
5. reap後に`kill(-pgid, 0) == -1 && errno == ESRCH`をboundedに観測する。観測できなければ`processGroupNotEmpty`とし、成功を返さない。
6. stdin／stdout／stderr taskをboundedにdrain／停止してfile descriptorをcloseする。

Darwinでは、終了済みだが未reapのleaderだけが残る期間のgroup probeが`EPERM`になり得る。anchor取得前の`EPERM`は直ちに「zombieだけ」と仮定せず、短いbounded loopでdirect childの`waitid(WNOWAIT)`観測を再試行する。deadlineまでanchorを得られない`EPERM`はpermission failureとしてfail-closedにする。anchorを保持した後の`EPERM`も最終的な「group empty」の証拠にせず、direct childをreapした後に`ESRCH`を再検査する。reap後に非`ESRCH`を観測しても、PGID reuseした無関係groupへsignalを送る危険を避けるため再signalせず、typed failureで終了する。

ここで確認できる`group empty`はprobe時点の瞬間的な観測である。direct childのPIDと開始時刻を使うwatchdogはテスト時の安全網であり、productionのparent-death保証ではない。

## 5. 保証しないこと

- macOSの親processは、自分のdirect childではないgrandchildを`waitpid`してreapできない。同一process groupのdescendantへTERM／KILLを送り消滅を観測するが、「全descendantをwaitpid／reapした」とは表現しない。
- descendantが`setsid`／`setpgid`、credential／権限変更等で元のgroupから脱出した場合、process-group signalだけでは回収できない。B2の合成helperはこの脱出を行わず、脱出拒否のOS-level containmentは未実装である。
- supervisorはFUMINIWA appと同じprocess内にある。appが`SIGKILL`、crash、power lossで停止するとcleanup code自体が実行されないため、parent death後の回収と一般的なorphan-freeを保証しない。独立した監査済みhelperまたは同等のOS lifecycle契約が別Gateとして必要である。
- reap直後のPGID reuse raceを完全には排除できない。実装はleaderをreap直前までanchorとして保持し、reap後は観測だけを行って無関係processへsignalしないが、`ESRCH`はその瞬間の状態だけを示す。
- 合成helperでの成功は、実Codex SDK／CLIのprocess tree、Nodeの子孫構造、network、API key、local artifact、OS-level file-read拒否を検証しない。

以上のため、Checkpoint B2完了後も実送信はNO-GOである。B3でnative manifest verifierを追加しても、compile-time approved digest allowlist、検証済みbytesとpath-based spawnのimmutable binding、exact Node runtime、監査済みlauncher／parent-death境界、専用cwd／`CODEX_HOME`、environment allowlist、Keychain one-shot credential pipe、OS-level sandbox、実SDK process treeとartifact inventoryは未完了である。これらを合成入力から個別に通した後で、既存のprovider-neutral UIへadapterを接続する。

## 6. 合成テストで固定する事実

- canonicalなabsolute executable／cwd、exact argv／environment、stdin、stdout、stderr byte count、exit code／signal termination
- group／world writable executableをspawn前に拒否すること
- 親の未許可sentinel file descriptorをchildが継承しないこと
- stdin 512 KiB、stdout 512 KiB、stderr 16 KiBの境界と超過時のtyped failure
- stdout 512 KiBとstderr 16 KiBを同時にexact capまでfloodしてもdeadlockせずdrainすること
- timeout、Swift Task cancel、重複`cancel()`でTERMを無視するleaderと同一group descendantをKILLし、direct childをreapしてpost-reap `ESRCH`を観測すること
- deadline後に観測した即時exitを成功へ戻さないこと
- spawn前にdeadlineへ達したrequestはchildを起動せず、stdinを1 byteも渡さないこと
- leaderが先に正常終了してlive descendantが残る場合、cleanupしても`lingeringDescendant`を返すこと
- 同じsupervisorの並行2件目とpre-cancelled consumerをspawn前に拒否すること

テスト用shell、PID file、watchdogは合成processの観測と失敗時cleanupにだけ使う。これらを実runtimeのidentity、artifact、隔離の証明へ流用しない。
