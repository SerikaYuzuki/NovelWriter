# Visual direction: 「藍と生成りの書斎」 (approved by reviewer; owner delegated UI taste decisions)

Palette derived from the app icon `Assets/Brand/fuminiwa-book-sprout-v1.png` (indigo #0B245E, unbleached paper #FAF2E4, young leaf #869C7C).

Principles
- Non-editor surfaces (shelf, work home, detail screens, settings) use warm paper surfaces. Sidebar and toolbar stay system material. The manuscript canvas stays exactly as the user configures it.
- Accent (indigo) only for selection, primary actions, links. Leaf only for completion/progress/synced. No large high-saturation fills.
- The user's own images (work cover, character avatar, world-note image) are the visual heroes; when absent, generate a tasteful placeholder from existing data so nothing looks empty.
- Work titles (cover, work home hero, work info heading) use Hiragino Mincho W6 with `relativeTo:` for Dynamic Type; everything else system font.
- Never add decoration to the manuscript text, EditorKit, IME, the canvas or the writing-assist bar. No number/symbol animations while typing, no hover effects in the editor.

Keep (deliberate product constraints in STYLE.md): independent manuscript canvas (§1, §3), appearance defaults (D-044/D-057), no placeholder for unimplemented features (D-040), sync display semantics (§6), one-row toolbar, no double material, 44pt hit targets.

STYLE.md changes (new wording, Japanese)
- §2 色: 「固定色はNovelUIの`FuminiwaColor` tokenと本文設定に限る。棚・作品ホーム・詳細はpaper／surfaceを面に使ってよい。accent（藍）は選択・主操作・リンク、leaf（若葉）は完了・進み具合に限り、大きな面を高彩度で塗らない。利用者の画像（表紙・人物・世界観）は面積の例外。Sidebar・toolbarはsystem material、本文は利用者設定のまま。」
- §3 文字に追加: 「作品名（表紙・作品ホーム・作品情報の見出し）に限りヒラギノ明朝W6を`relativeTo:`付きで使う。」
- §4: 「角丸8／4pt、常設の影なし」→「角丸は`Radius` token（continuous）。影は表紙サムネイルの1層とドラッグ中のカードだけ。」
- §5 部品に追加: thumbnail sizes; status = symbol + text (never color alone); empty states carry real action buttons.
- §7 動きに追加: 「`Motion.standard`を使い、Reduce Motion時はnil。本文入力中に数値や記号のアニメーションを動かさない。」

Tokens (new `NovelKit/Sources/NovelUI/Theme/`; NovelUI depends on nothing but NovelCore)

| token | Light | Dark | use |
|---|---|---|---|
| paper | #F8F5EF | #18181B | shelf/home/detail background |
| surface | #FFFDF9 | #212126 | cards |
| elevatedSurface | #FFFFFF | #2A2A30 | selected / popover content |
| sunken | #F0ECE3 | #131316 | well under cards |
| separator | #E3DDD1 | #3A3B42 | custom card hairlines only |
| textPrimary | #23211D | #ECE9E2 | text on paper (else `.primary`) |
| textSecondary | #6B655B | #A6A29A | secondary |
| textTertiary | #9A9488 | #706C66 | tertiary |
| accent | #34558B | #8CA7DF | (existing values) |
| accentMuted | #E4E9F3 | #263049 | selection fills, chips, bubbles |
| leaf/success | #50704A | #9DB58E | done/progress/synced |
| warning | #9A5A00 (text; icon may use #B96A00) | #E8A54A | caution |
| danger | #B3413B | #E07A7A | destructive accents |

Verify contrast ≥4.5:1 for text pairs in tests (compute in a unit test). Respect Increase Contrast / Reduce Transparency via system.

Sync state tones: synced=leaf, syncing/not-downloaded=accent, pending/device-only=secondary, offline=tertiary, conflict=warning, failed=danger — always symbol + text. Wording comes from the shared `NovelSyncV2Application` mapping (U-02); NovelUI renders `StatusTone` + text + symbol only.

Type: `.largeTitle` shelf heading; `.title2.semibold` detail hero names (work names in Mincho); `.headline` group headings/card titles; `.body` rows/forms; row secondary iOS `.subheadline` / macOS `.caption` secondary; `.caption2` meta; numbers `.monospacedDigit()`.
Spacing: 2,4,8,12,16,20,24,32,48 (keep outer 20 / between groups 16 / within 8).
Radius (continuous): chip 4, thumbnail 6, card 10, hero 14; book cover 4 + inner hairline.
Shadow: covers only — black 0.12 light / 0.4 dark, radius 3, y 1; dragged cards only otherwise. Material: only existing `workbenchGlassChromeStyle`.
Icons: SF Symbols `.hierarchical`, system weight.
Thumbnail sizes: cover 2:3 list 32×48, grid width 120–150 (iOS adaptive 104–140), home hero 96×144. Character circle list 24 (macOS)/28 (iOS), detail 72. World rounded square list 28, detail 96.
Placeholders (no new data): cover = paper + indigo band + first character of title (Mincho); character = circle filled with `colorHex` + initial (neutral when no color); world = accentMuted square + `globe.asia.australia`.
Motion: `Motion.standard` (short ease), nil under Reduce Motion.
Accent asset: add the same `AccentColor` asset to iOS and remove `IOSPalette.accent`. Give the 10 character color swatches Japanese names (紅, 柿, …) for help/VoiceOver instead of hex.

Screen plan (priority)
1 S Foundation: tokens + Motion; replace hard-coded colors (`LibraryPane.swift:288-292`, `ExplicitSyncButton.swift:32`, `IOSLibraryViewV2.swift:72`, `IOSProjectHomeViewV2.swift:45`) and `.system(size:48)` (`LibraryWindowView.swift:13`); Reduce Motion for `OutlineView.swift:32`, `EditorPaneView.swift:67`. Unify sidebar icons/names in one `ProjectSectionStyle` used by macOS (`AppMode.swift:39-57`), iPad (`IOSRegularProjectSidebar.swift:22-53`) and iPhone; macOS sidebar section headers 「この作品」「アプリ」; unresolved-foreshadowing count via native `.badge`.
2 L Shelf: grid/list toggle (toolbar Picker, remembered per device), covers + Mincho title + status badge; macOS left panel uses the book-and-sprout brand image on paper; collapse the five icon-only buttons into 「新規」 + 「…」 menu; iOS: account/sign-in in its own 「アカウント」 section, 「＋」 menu for new/import (「作品を取り込む…」). No greeting, no "today's words", no recently-opened ordering.
3 M iOS work home: hero (cover, Mincho title, synopsis 3 lines) + stats (文字数 / 400字詰め枚数 / 章 / 話) from existing data; features as 2-column tiles with icons and counts (人物 n, 世界観 n, プロット n, 伏線 未回収 n, 資料 n); sync as a one-line badge, warning card with the existing 3 choices only on conflict; move 履歴 and 書き出し under 「その他」.
4 M Characters (both): avatar rows (replace the 8pt dot; add to iOS); detail hero (avatar 72, name, furigana, role chips) + card sections; color swatch selection with ring + checkmark, help shows color name.
5 M World notes: 28pt thumbnail in rows; detail shows a hero only when an image exists; keep the text editing area as is.
6 M Plot/flags: cards on surface, radius 10, hairline; selected = 1.5pt accent ring; macOS hover slightly brightens; shadow only while dragging; empty = dashed drop area; iPad regular width card grid, iPhone list with icon + 2-line memo. Flags: unresolved `flag` (warning), resolved `checkmark.circle.fill` (leaf), same on iOS.
7 S Work info: remove 「保存形式 .novelpkg v3」 (`NovelWorkbenchView.swift:673`); cover + stat tiles; same structure on iOS.
8 S Editor chrome (not text): work-title header background = canvas color + bottom hairline, title in secondary (`NovelWorkbenchView.swift:315-327`); sync button `titleAndIcon` with state tone, `.pulse` only while syncing and not under Reduce Motion (`ExplicitSyncButton.swift`).
9 S Settings: macOS sections 外観 / 本文 / AI支援, `LabeledContent` with right-aligned values, a preview line of body text using the user's colors and font (`EditorSettings.swift:242-306`); iOS section headers with icon labels.
10 S AI panel: header `sparkles` + accent; answers on surface cards; chat: user messages right-aligned accentMuted bubbles, AI left-aligned plain text (`AssistantPanelView.swift:35-45`, `AssistantChatView.swift:106-108`).
11 S Conflict + empty states: the three conflict choices become equal-weight `.bordered` rows with icon + title + description (no implied winner, STYLE §6) (`ContentView.swift:131-135`); macOS empty states get real action buttons via `ContentUnavailableView` `actions:`.

Guardrails
- Performance: cache character counts (`WritingOutlineSupport.swift:79-81`) and character appearance detection (`CharacterModeView.swift:309-312`) before adding stats/tiles; thumbnails decoded at display size, cached, `LazyVGrid`; keep away from the save path.
- Window sizes: macOS min width 700, outline 224; iPad Split View; iPhone AX Dynamic Type (grid falls back to list at AX sizes).
- Update STYLE.md (and DECISIONS if appearance defaults are touched) first, then tokens → shelf/home → detail screens. Check System/Light/Dark and VoiceOver at each step.
