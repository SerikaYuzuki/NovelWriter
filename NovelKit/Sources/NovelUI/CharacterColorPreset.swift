/// キャラクターカラーの既定プリセット(docs/STYLE.md 2章)。
///
/// ユーザーは `ColorPicker` で任意色も選べるが、既定の候補としてこの10色を
/// スウォッチで提示する。両モード(ライト/ダーク)で背景とのコントラストを
/// 確認済みの中間トーン。
public enum CharacterColorPreset {
    public static func name(for hex: String) -> String {
        let names = ["紅", "柿", "芥子", "松", "青磁", "縹", "藤紫", "菖蒲", "梅紫", "胡桃"]
        guard let index = hexValues.firstIndex(of: hex) else { return "選択した色" }
        return names[index]
    }

    /// STYLE.md で定義された10色。並び順は STYLE.md の記載順。
    public static let hexValues: [String] = [
        "#C25450", // 紅
        "#C97F3D", // 柿
        "#B89A3A", // 芥子
        "#5B9160", // 松
        "#4E9091", // 青磁
        "#5077B0", // 縹
        "#6A6FB2", // 藤紫
        "#8E6AA8", // 菖蒲
        "#B0628C", // 梅紫
        "#8A7A6A" // 胡桃
    ]
}
