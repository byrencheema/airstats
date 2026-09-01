import Testing
import Foundation
@testable import AirStatKit
@testable import AirStatUI

@Suite("The combine switch decides how many status items the bar gets")
struct MenuBarItemLayoutTests {

    private let cpu = MenuBarItemConfig(metric: .cpuUsage, style: .text)
    private let memory = MenuBarItemConfig(metric: .memoryUsage, style: .text)
    private let gpu = MenuBarItemConfig(metric: .gpuUsage, style: .text)

    @Test("combined means one item, however many readouts are enabled")
    func combinedIsOneItem() {
        let settings = MenuBarSettings(items: [cpu, memory, gpu], usesCombinedItem: true)
        #expect(MenuBarItemLayout(settings: settings) == .combined)
    }

    @Test("separate means one item per enabled readout, in the configured order")
    func separateFollowsConfiguredOrder() {
        var disabled = gpu
        disabled.isEnabled = false
        let settings = MenuBarSettings(items: [memory, disabled, cpu], usesCombinedItem: false)
        #expect(MenuBarItemLayout(settings: settings) == .separate([memory.id, cpu.id]))
    }

    /// The layout is the whole of what the controller compares, so a switch flip has to
    /// show up here or nothing rebuilds.
    @Test("flipping the switch changes the layout either way")
    func flippingChangesLayout() {
        let items = [cpu, memory]
        let combined = MenuBarItemLayout(settings: MenuBarSettings(items: items, usesCombinedItem: true))
        let separate = MenuBarItemLayout(settings: MenuBarSettings(items: items, usesCombinedItem: false))
        #expect(combined != separate)
    }

    @Test("reordering the readouts changes the layout")
    func reorderingChangesLayout() {
        let forwards = MenuBarItemLayout(settings: MenuBarSettings(items: [cpu, memory],
                                                                   usesCombinedItem: false))
        let backwards = MenuBarItemLayout(settings: MenuBarSettings(items: [memory, cpu],
                                                                    usesCombinedItem: false))
        #expect(forwards != backwards)
    }

    /// Separate items with nothing to draw would leave the menu bar empty and the app
    /// with no click target at all.
    @Test("nothing enabled falls back to the combined item")
    func emptyFallsBackToCombined() {
        var off = cpu
        off.isEnabled = false
        let settings = MenuBarSettings(items: [off], usesCombinedItem: false)
        #expect(MenuBarItemLayout(settings: settings) == .combined)
    }

    /// The hidden switch outranks everything else, including the empty-bar fallback
    /// that otherwise insists on a click target: hiding is the one case where no item
    /// is what the user asked for.
    @Test("hidden means no item, whatever the combine switch or readouts say")
    func hiddenMeansNoItem() {
        for combined in [true, false] {
            let settings = MenuBarSettings(items: [cpu, memory], usesCombinedItem: combined,
                                           isVisible: false)
            #expect(MenuBarItemLayout(settings: settings) == .hidden)
        }
        var off = cpu
        off.isEnabled = false
        let empty = MenuBarSettings(items: [off], usesCombinedItem: false, isVisible: false)
        #expect(MenuBarItemLayout(settings: empty) == .hidden)
    }

    @Test("a settings file from before the hidden switch shows the item")
    func decodingDefaultsToVisible() throws {
        let json = Data(#"{"items":[],"usesCombinedItem":true}"#.utf8)
        let decoded = try JSONDecoder().decode(MenuBarSettings.self, from: json)
        #expect(decoded.isVisible)
    }
}

@MainActor
@Suite("Separate status items keep their place and draw their own readout")
struct StatusItemControllerLayoutTests {

    @Test("the combined item keeps the autosave name it has always had")
    func combinedAutosaveNameIsUnchanged() {
        #expect(StatusItemController.combinedAutosaveName == "AirStatsStatusItem")
    }

    /// Positions are saved against these names, so two readouts must never share one
    /// and a name must not move when anything else about the readout changes.
    @Test("each readout gets a distinct, stable autosave name")
    func autosaveNamesAreDistinctAndStable() {
        let first = UUID()
        let second = UUID()
        #expect(StatusItemController.autosaveName(for: first)
                != StatusItemController.autosaveName(for: second))
        #expect(StatusItemController.autosaveName(for: first)
                == StatusItemController.autosaveName(for: first))
        #expect(StatusItemController.autosaveName(for: first)
                != StatusItemController.combinedAutosaveName)
    }

    @Test("a per-item model carries one readout and the whole bar's drawing settings")
    func sliceNarrowsToOneReadout() {
        let items = [MenuBarItemConfig(metric: .cpuUsage, style: .text),
                     MenuBarItemConfig(metric: .memoryUsage, style: .textAndGraph),
                     MenuBarItemConfig(metric: .networkThroughput, style: .text)]
        let model = self.model(items: items)
        #expect(model.items.count == 3)

        let slice = StatusItemController.slice(model, readout: items[1].id)
        #expect(slice.items.map(\.id) == [items[1].id])
        #expect(slice.items.first == model.items[1])
        #expect(slice.spacing == model.spacing)
        #expect(slice.usesFixedWidth == model.usesFixedWidth)
        #expect(slice.usesMonospacedDigits == model.usesMonospacedDigits)
        #expect(slice.isStale == model.isStale)
    }

    @Test("the combined item is fed the whole bar")
    func sliceForCombinedIsEverything() {
        let model = self.model(items: [MenuBarItemConfig(metric: .cpuUsage, style: .text),
                                       MenuBarItemConfig(metric: .memoryUsage, style: .text)])
        #expect(StatusItemController.slice(model, readout: nil) == model)
    }

    /// VoiceOver reads each item on its own now, so an item must not announce its
    /// neighbours' numbers.
    @Test("an item describes only its own readout")
    func sliceDescribesOnlyItsOwnReadout() {
        let items = [MenuBarItemConfig(metric: .cpuUsage, style: .text),
                     MenuBarItemConfig(metric: .memoryUsage, style: .text)]
        let model = self.model(items: items)
        let slice = StatusItemController.slice(model, readout: items[0].id)
        #expect(slice.accessibilityDescription == model.items[0].accessibilityLabel)
        #expect(!slice.accessibilityDescription.contains("Memory"))
    }

    /// Each item redraws only when its own model changes, so a slice must not move when
    /// another readout's value does.
    @Test("a readout's slice is unchanged by another readout's value")
    func sliceIgnoresOtherReadouts() {
        let items = [MenuBarItemConfig(metric: .cpuUsage, style: .text),
                     MenuBarItemConfig(metric: .memoryUsage, style: .text)]
        var busier = SnapshotFixtures.nominal
        busier.memory = .value(SnapshotFixtures.memory(usedFraction: 0.91, pressure: 0.44))

        let before = StatusItemController.slice(model(items: items), readout: items[0].id)
        let after = StatusItemController.slice(model(items: items, snapshot: busier),
                                               readout: items[0].id)
        #expect(before == after)
    }

    private func model(items: [MenuBarItemConfig],
                       snapshot: SystemSnapshot = SnapshotFixtures.nominal) -> MenuBarRenderModel {
        MenuBarRenderModel(snapshot: snapshot,
                           history: SnapshotFixtures.history(),
                           settings: Settings(menuBar: MenuBarSettings(items: items,
                                                                       usesCombinedItem: false)),
                           isStale: false)
    }
}
