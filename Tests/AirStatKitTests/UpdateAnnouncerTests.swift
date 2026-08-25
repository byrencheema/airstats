import Testing
import Foundation
@testable import AirStatUI

/// A scheduled update says two things: a row in the panel, which stands for as long as
/// the update is outstanding, and one notification, which is an event. Only the second
/// can go wrong quietly, and only a release later: announce on the wrong predicate and
/// every launch posts a banner for an update the user already declined, or a release
/// ships and nobody is told. So the predicate is pure and it is tested.
@Suite("An update is announced once per release")
struct UpdateAnnouncerTests {

    @Test("a release nobody has been told about is announced")
    func announcesFirstTime() {
        #expect(UpdateAnnouncer.shouldAnnounce(pending: "1.2", announced: nil))
    }

    @Test("the same release is never announced twice")
    func doesNotNag() {
        #expect(!UpdateAnnouncer.shouldAnnounce(pending: "1.2", announced: "1.2"))
    }

    @Test("the release after an announced one still speaks")
    func announcesNextRelease() {
        #expect(UpdateAnnouncer.shouldAnnounce(pending: "1.3", announced: "1.2"))
    }

    /// Sparkle reports no pending update whenever the session ends, including when the
    /// user installed the thing, and an empty display version is a release that arrived
    /// without one.
    @Test("nothing is announced with nothing pending")
    func staysQuietWithoutAnUpdate() {
        #expect(!UpdateAnnouncer.shouldAnnounce(pending: nil, announced: "1.2"))
        #expect(!UpdateAnnouncer.shouldAnnounce(pending: "", announced: nil))
    }

    @Test("an update that will install itself is not announced")
    func staysQuietWhenInstallingAutomatically() {
        #expect(!UpdateAnnouncer.shouldAnnounce(pending: "1.3", announced: nil, installsAutomatically: true))
    }
}

/// The row survives a relaunch by being written down, and what is written down has to
/// be judged against the bundle that reads it back: an install leaves the record for
/// the version now running, and showing that as news would be a row that never clears.
@Suite("A pending update outlives the process")
struct PendingUpdateTests {

    @Test("a newer build than the one running is restored")
    func restoresNewer() {
        #expect(SoftwareUpdater.shouldRestore(pendingBuild: "8", runningBuild: "7"))
        #expect(SoftwareUpdater.shouldRestore(pendingBuild: "10", runningBuild: "9"))
    }

    @Test("the running build, or an older one, is dropped")
    func dropsInstalled() {
        #expect(!SoftwareUpdater.shouldRestore(pendingBuild: "7", runningBuild: "7"))
        #expect(!SoftwareUpdater.shouldRestore(pendingBuild: "6", runningBuild: "7"))
        #expect(!SoftwareUpdater.shouldRestore(pendingBuild: "", runningBuild: "7"))
        #expect(!SoftwareUpdater.shouldRestore(pendingBuild: "8", runningBuild: nil))
    }

    /// Sparkle reports the same item from several delegates in no fixed order, and a
    /// "found" arriving after "staged" is the same update again, not a step back.
    @Test("the stage climbs and never falls")
    func stageOnlyClimbs() {
        let ready = PendingUpdate(version: "1.4", build: "8", stage: .ready)
        let found = PendingUpdate(version: "1.4", build: "8", stage: .available)
        #expect(SoftwareUpdater.merge(current: ready, incoming: found).stage == .ready)
        #expect(SoftwareUpdater.merge(current: found, incoming: ready).stage == .ready)
        #expect(SoftwareUpdater.merge(current: nil, incoming: found).stage == .available)
    }

    @Test("a different release replaces the record outright")
    func newReleaseReplaces() {
        let ready = PendingUpdate(version: "1.4", build: "8", stage: .ready)
        let next = PendingUpdate(version: "1.5", build: "9", stage: .available)
        #expect(SoftwareUpdater.merge(current: ready, incoming: next) == next)
    }
}
