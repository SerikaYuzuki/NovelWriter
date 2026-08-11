@testable import FUMINIWAIOS
import SwiftUI
import Testing
import UIKit

@Suite("iOS app appearance")
struct IOSAppearanceTests {
    @Test("初回の外観はダークになる")
    func initialAppearanceIsDark() {
        #expect(IOSAppearance.initialRawValue == IOSAppearance.dark.rawValue)
        #expect(IOSAppearance(storedRawValue: nil) == .dark)
    }

    @Test("保存済みの外観raw valueを復元する")
    func storedRawValuesAreRestored() {
        for appearance in IOSAppearance.allCases {
            #expect(IOSAppearance(storedRawValue: appearance.rawValue) == appearance)
        }
    }

    @Test("未知の保存値はシステムに合わせるへ戻る")
    func unknownStoredValueFallsBackToSystem() {
        #expect(IOSAppearance(storedRawValue: "future-appearance") == .system)
        #expect(IOSAppearance(storedRawValue: "") == .system)
    }

    @Test("外観はSwiftUIの標準ColorSchemeへ写像される")
    func appearanceMapsToColorScheme() {
        #expect(IOSAppearance.system.colorScheme == nil)
        #expect(IOSAppearance.light.colorScheme == ColorScheme.light)
        #expect(IOSAppearance.dark.colorScheme == ColorScheme.dark)
    }

    @Test("外観ラベルとアイコンを提供する")
    func appearanceProvidesLabelsAndIcons() {
        #expect(IOSAppearance.system.title == "システムに合わせる")
        #expect(IOSAppearance.light.title == "ライト")
        #expect(IOSAppearance.dark.title == "ダーク")
        #expect(IOSAppearance.system.systemImage == "circle.lefthalf.filled")
        #expect(IOSAppearance.light.systemImage == "sun.max")
        #expect(IOSAppearance.dark.systemImage == "moon.fill")
    }

    @Test("UserDefaultsへraw valueを保存して復元できる")
    func rawValueRoundTripsThroughUserDefaults() throws {
        let suiteName = "dev.serikayuzuki.fuminiwa.ios.appearance-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        #expect(
            IOSAppearance(storedRawValue: defaults.string(forKey: IOSAppearance.preferenceKey)) == .dark
        )

        defaults.set(IOSAppearance.light.rawValue, forKey: IOSAppearance.preferenceKey)
        #expect(
            IOSAppearance(storedRawValue: defaults.string(forKey: IOSAppearance.preferenceKey)) == .light
        )

        defaults.set("future-appearance", forKey: IOSAppearance.preferenceKey)
        #expect(
            IOSAppearance(storedRawValue: defaults.string(forKey: IOSAppearance.preferenceKey)) == .system
        )
    }

    @MainActor
    @Test("表示設定はFormを入れ子にせず1つの一覧として表示する")
    func settingsUsesSingleFormContainer() async throws {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-Appearance-Tests-\(id)", isDirectory: true)
        let suiteName = "dev.serikayuzuki.fuminiwa.ios.appearance-layout-tests.\(id)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: root)
        let host = UIHostingController(
            rootView: NavigationStack {
                IOSSettingsView(store: store, userDefaults: defaults)
            }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = host
        host.view.frame = window.bounds
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        for _ in 0 ..< 8 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await Task.yield()
        }

        let listContainers = descendantViews(of: host.view).filter {
            $0 is UICollectionView || $0 is UITableView
        }
        #expect(listContainers.count == 1)
    }

    @MainActor
    private func descendantViews(of root: UIView) -> [UIView] {
        root.subviews.flatMap { child in
            [child] + descendantViews(of: child)
        }
    }
}
