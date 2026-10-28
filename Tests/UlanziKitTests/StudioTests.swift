import XCTest
import JavaScriptCore
import IOKit.hidsystem
@testable import UlanziKit

final class StudioTests: XCTestCase {
    private func page(_ layer: StudioLayer) -> StudioPage {
        var page = StudioPage(name: layer.name, layers: [layer]); page.id = layer.id; return page
    }
    func testPageNavigationWrapsAndSelectionIsIndependentPerProfile() {
        let a = StudioPage(name: "A"), b = StudioPage(name: "B"), c = StudioPage(name: "C")
        let other = StudioPage(name: "Other"), other2 = StudioPage(name: "Other2")
        let first = StudioProfile(name: "First", bundleID: "a", pages: [a, b, c])
        let second = StudioProfile(name: "Second", bundleID: "b", pages: [other, other2])
        let engine = LayerEngine(StudioConfiguration(profiles: [first, second])); engine.updateContext(AppContext(bundleID: "a"))
        XCTAssertTrue(engine.applyStateAction(StudioAction(.previousPage), control: .topLeft)); XCTAssertEqual(engine.layer?.id, c.id)
        XCTAssertTrue(engine.applyStateAction(StudioAction(.cycleLayer), control: .topLeft)); XCTAssertEqual(engine.layer?.id, a.id)
        XCTAssertTrue(engine.applyStateAction(StudioAction(.switchLayer, layer: b.id), control: .topLeft)); XCTAssertEqual(engine.layer?.id, b.id)
        engine.updateContext(AppContext(bundleID: "b")); engine.selectLayer(other2.id)
        engine.updateContext(AppContext(bundleID: "a")); XCTAssertEqual(engine.layer?.id, b.id)
        engine.updateContext(AppContext(bundleID: "b")); XCTAssertEqual(engine.layer?.id, other2.id)
    }
    func testPageNavigationActionsDispatchOnPhysicalEvents() {
        var bottom = StudioLayer(name: "Bottom")
        bottom.bindings = [StudioBinding(control: .topLeft, gesture: .tap, action: StudioAction(.previousPage))]
        let a = StudioPage(name: "A", layers: [bottom]), b = StudioPage(name: "B")
        let engine = LayerEngine(StudioConfiguration(profiles: [StudioProfile(pages: [a, b])]))
        engine.updateContext(AppContext())
        engine.handle(ControlEvent(.topLeft, .down)); engine.handle(ControlEvent(.topLeft, .up))
        XCTAssertEqual(engine.layer?.id, b.id)
        XCTAssertTrue(ActionType.previousPage.isLayer)
        XCTAssertTrue(ActionType.cycleLayer.isLayer)
    }
    func testRapidShortcutRotationDoesNotCrowdOutButton() {
        let started = expectation(description: "blocked first action")
        let finished = expectation(description: "all actions")
        finished.expectedFulfillmentCount = 26
        let release = DispatchSemaphore(value: 0), lock = NSLock()
        var calls: [String] = []
        let executor = StudioActionExecutor { invocation in
            let name = invocation.binding.action.value
            lock.lock(); calls.append(name); lock.unlock()
            if name == "block" { started.fulfill(); _ = release.wait(timeout: .now() + 3) }
            finished.fulfill(); return ""
        }
        let profile = StudioProfile(), layer = StudioLayer(), context = AppContext()
        func call(_ binding: StudioBinding) -> ActionInvocation { ActionInvocation(binding: binding, profile: profile, layer: layer, context: context) }
        let block = StudioBinding(control: .topLeft, gesture: .tap, action: StudioAction(.midi, value: "block"))
        let dial = StudioBinding(control: .dial, gesture: .clockwise, action: StudioAction(.shortcut, value: "cmd+right"))
        let button = StudioBinding(control: .topRight, gesture: .tap, action: StudioAction(.midi, value: "button"))
        executor.execute(call(block)); wait(for: [started], timeout: 2)
        for _ in 0..<24 { executor.execute(call(dial)) }
        executor.execute(call(button)); release.signal()
        wait(for: [finished], timeout: 3)
        lock.lock(); let result = calls; lock.unlock()
        XCTAssertEqual(result.first, "block")
        XCTAssertEqual(result.filter { $0 == "cmd+right" }.count, 24)
        XCTAssertEqual(result.last, "button")
    }
    func testInputDoesNotEmitUnchangedState() {
        let config = StudioConfiguration.starter
        let engine = LayerEngine(config)
        engine.updateContext(AppContext(bundleID: "com.google.Chrome"))
        var changes = 0; engine.onChange = { changes += 1 }
        for _ in 0..<20 { engine.handle(ControlEvent(.dial, .rotate, delta: 1)) }
        XCTAssertEqual(changes, 0)
        engine.handle(ControlEvent(.leftTop, .down))
        XCTAssertGreaterThan(changes, 0)
        let afterDown = changes
        engine.handle(ControlEvent(.leftTop, .up))
        XCTAssertGreaterThan(changes, afterDown)
    }
    func testAppendSequenceAndPersistDelay() throws {
        var config = StudioConfiguration.starter
        let profile = config.profiles[0], layer = profile.pages[0].layers[0], binding = layer.bindings[1]
        let seek = try XCTUnwrap(ActionTemplate.all.first { $0.id == "system.seek" })
        try config.append(seek, profileID: profile.id, layerID: layer.id, bindingID: binding.id)
        let index = try XCTUnwrap(config.profiles[0].pages[0].layers[0].bindings.firstIndex { $0.id == binding.id })
        config.profiles[0].pages[0].layers[0].bindings[index].steps![0].delayMilliseconds = 250
        let decoded = try JSONDecoder().decode(StudioConfiguration.self, from: JSONEncoder().encode(config))
        try decoded.validate()
        XCTAssertEqual(decoded.profiles[0].pages[0].layers[0].bindings[index].steps?.first?.delayMilliseconds, 250)
        XCTAssertEqual(decoded.profiles[0].pages[0].layers[0].bindings[index].steps?.first?.action.amount, -5)
        config.profiles[0].pages[0].layers[0].bindings[index].steps![0].delayMilliseconds = -1
        XCTAssertThrowsError(try config.validate())
    }
    func testSequenceOrderDelayAndStateActions() throws {
        let finished = expectation(description: "sequence completed")
        let lock = NSLock()
        var calls: [String] = []
        var times: [TimeInterval] = []
        func record(_ name: String) { lock.lock(); calls.append(name); times.append(ProcessInfo.processInfo.systemUptime); lock.unlock() }
        let executor = StudioActionExecutor { call in record(call.binding.action.value); return "" }
        executor.onStateAction = { _, _, isCurrent in XCTAssertTrue(isCurrent()); record("layer") }
        executor.onResult = { _, success in XCTAssertTrue(success); finished.fulfill() }
        var binding = StudioBinding(action: StudioAction(.midi, value: "first"))
        binding.steps = [ActionStep(action: StudioAction(.switchLayer), delayMilliseconds: 80), ActionStep(action: StudioAction(.midi, value: "last"))]
        executor.execute(ActionInvocation(binding: binding, profile: StudioProfile(), layer: StudioLayer(), context: AppContext()))
        wait(for: [finished], timeout: 2)
        lock.lock(); let result = calls; let recordedTimes = times; lock.unlock()
        XCTAssertEqual(result, ["first", "layer", "last"])
        XCTAssertGreaterThanOrEqual(recordedTimes[1] - recordedTimes[0], 0.06)
    }
    func testWaitingSequenceDoesNotDelayAnotherInput() {
        let firstStarted = expectation(description: "sequence started")
        let otherRan = expectation(description: "other input ran while sequence waited")
        let release = DispatchSemaphore(value: 0)
        let executor = StudioActionExecutor { invocation in
            if invocation.binding.action.value == "first" { firstStarted.fulfill(); _ = release.wait(timeout: .now() + 3) }
            if invocation.binding.action.value == "other" { otherRan.fulfill() }
            return ""
        }
        var sequence = StudioBinding(control: .leftTop, gesture: .press, action: StudioAction(.midi, value: "first"))
        sequence.steps = [ActionStep(action: StudioAction(.midi, value: "second"))]
        let other = StudioBinding(control: .rightTop, gesture: .press, action: StudioAction(.midi, value: "other"))
        let profile = StudioProfile(), layer = StudioLayer(), context = AppContext()
        executor.execute(ActionInvocation(binding: sequence, profile: profile, layer: layer, context: context))
        wait(for: [firstStarted], timeout: 2)
        executor.execute(ActionInvocation(binding: other, profile: profile, layer: layer, context: context))
        wait(for: [otherRan], timeout: 1)
        release.signal()
    }
    func testDelayedContinuousStepAfterReleaseSkipsOnlyThatStep() throws {
        let started = expectation(description: "first action")
        let finished = expectation(description: "sequence completes")
        let lock = NSLock(); var calls: [String] = []
        func record(_ value: String) { lock.lock(); calls.append(value); lock.unlock() }
        let overlay = StudioLayer(name: "Overlay")
        var binding = StudioBinding(name: "sequence", control: .leftTop, gesture: .press, action: StudioAction(.midi, value: "first"))
        binding.steps = [ActionStep(action: StudioAction(.overlayHold, layer: overlay.id), delayMilliseconds: 500), ActionStep(action: StudioAction(.midi, value: "last"))]
        let config = StudioConfiguration(profiles: [StudioProfile(pages: [StudioPage(layers: [StudioLayer(bindings: [binding]), overlay])])]); try config.validate()
        let engine = LayerEngine(config); engine.updateContext(AppContext())
        let executor = StudioActionExecutor { invocation in
            record(invocation.binding.action.value)
            if invocation.binding.action.value == "first" { started.fulfill() }
            return ""
        }
        executor.onStateAction = { action, invocation, isCurrent in
            DispatchQueue.main.sync {
                guard isCurrent() else { return }
                if engine.isPressActive(invocation.pressID, control: invocation.binding.control) {
                    _ = engine.applyStateAction(action, control: invocation.binding.control, pressID: invocation.pressID)
                } else { record("skipped") }
            }
        }
        executor.onResult = { _, success in XCTAssertTrue(success); finished.fulfill() }
        engine.onAction = { executor.execute($0) }
        engine.handle(ControlEvent(.leftTop, .down), now: 1)
        wait(for: [started], timeout: 2)
        engine.handle(ControlEvent(.leftTop, .up), now: 1.1)
        wait(for: [finished], timeout: 3)
        lock.lock(); let recorded = calls; lock.unlock()
        XCTAssertEqual(recorded, ["first", "skipped", "last"])
        XCTAssertTrue(engine.activeOverlays.isEmpty)
    }
    func testSequenceStopsOnErrorAndCancellation() {
        for cancel in [false, true] {
            let first = expectation(description: "first action")
            let done = expectation(description: "sequence stopped")
            let lock = NSLock(); var calls: [String] = []
            let executor = StudioActionExecutor { call in
                lock.lock(); calls.append(call.binding.action.value); lock.unlock()
                first.fulfill()
                if !cancel { throw ConfigError("failure") }
                return ""
            }
            executor.onResult = { _, success in XCTAssertFalse(success); done.fulfill() }
            var binding = StudioBinding(action: StudioAction(.midi, value: "first"))
            binding.steps = [ActionStep(action: StudioAction(.midi, value: "second"), delayMilliseconds: 500)]
            executor.execute(ActionInvocation(binding: binding, profile: StudioProfile(), layer: StudioLayer(), context: AppContext()))
            wait(for: [first], timeout: 2)
            if cancel { executor.cancelPending() }
            wait(for: [done], timeout: 2)
            lock.lock(); let result = calls; lock.unlock()
            XCTAssertEqual(result, ["first"])
        }
    }
    func testRecordedShortcutRoundTripsPhysicalKeyAndModifiers() throws {
        let flags: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        let spec = try XCTUnwrap(InputMonitor.KeySpec.recorded(keyCode: 6, flags: flags))
        let (key, parsedFlags) = try InputMonitor.KeySpec.parse(spec)
        XCTAssertEqual(key, 6)
        XCTAssertEqual(parsedFlags, flags)
        XCTAssertEqual(InputMonitor.KeySpec.recorded(keyCode: 49, flags: []), "space")
        XCTAssertEqual(try InputMonitor.KeySpec.parse("keypadmultiply").0, 67)
        XCTAssertNil(InputMonitor.KeySpec.recorded(keyCode: 0xffff, flags: []))
    }
    func testDisplayPreferencesDecodeExistingConfiguration() throws {
        let encoded = try JSONEncoder().encode(StudioConfiguration.starter)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "hudPosition"); old.removeValue(forKey: "menuBarOnly")
        let loaded = try JSONDecoder().decode(StudioConfiguration.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(loaded.hudPosition, .bottomCenter)
        XCTAssertFalse(loaded.menuBarOnly)
        var updated = loaded; updated.hudPosition = .topRight; updated.menuBarOnly = true; updated.showHUD = false
        XCTAssertEqual(try JSONDecoder().decode(StudioConfiguration.self, from: JSONEncoder().encode(updated)), updated)
    }
    func testChromeWorkerReuseAndTimeout() throws {
        let worker = ChromeScriptWorker(executable: "/bin/zsh", arguments: ["-c", "while IFS= read -r line; do print -r -- '{\"result\":\"ok\"}'; done"])
        XCTAssertEqual(try worker.execute("first", timeout: 1), "ok")
        XCTAssertEqual(try worker.execute("second", timeout: 1), "ok")
        let stuck = ChromeScriptWorker(executable: "/bin/sleep", arguments: ["5"])
        let start = Date()
        XCTAssertThrowsError(try stuck.execute("request", timeout: 0.15))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testSystemMediaActionsAndVolumeDirections() throws {
        let volume = try XCTUnwrap(ActionTemplate.all.first { $0.id == "system.volume" })
        var config = StudioConfiguration.starter
        let profile = config.profiles[0], layer = profile.pages[0].layers[0]
        _ = try config.assign(volume, profileID: profile.id, layerID: layer.id, control: .dial, gesture: .counterclockwise)
        let action = try XCTUnwrap(config.profiles[0].pages[0].layers[0].bindings.first { $0.control == .dial && $0.gesture == .counterclockwise }).action
        XCTAssertEqual(action.type, .media)
        XCTAssertEqual(action.amount, -1)
        try config.validate()
        for key in [NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN, NX_KEYTYPE_MUTE, NX_KEYTYPE_PLAY, NX_KEYTYPE_PREVIOUS, NX_KEYTYPE_NEXT] {
            XCTAssertNotNil(InputMonitor.mediaEvent(Int(key), pressed: true))
            XCTAssertNotNil(InputMonitor.mediaEvent(Int(key), pressed: false))
        }
    }
    func testSystemSeekBounds() throws {
        XCTAssertEqual(try SystemMedia.target(elapsed: 10, duration: 20, delta: -15), 0)
        XCTAssertEqual(try SystemMedia.target(elapsed: 10, duration: 20, delta: 15), 20)
        XCTAssertEqual(try SystemMedia.target(elapsed: 10, duration: nil, delta: 0.5), 10.5)
    }
    func testRapidSeekCoalescesWithoutCrossingOtherActions() {
        let started = expectation(description: "first action started")
        let finished = expectation(description: "three actions completed")
        finished.expectedFulfillmentCount = 3
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var observed: [(String, Double)] = []
        let executor = StudioActionExecutor { invocation in
            lock.lock(); observed.append((invocation.binding.action.value, invocation.binding.action.amount)); let count = observed.count; lock.unlock()
            if count == 1 { started.fulfill(); _ = release.wait(timeout: .now() + 3) }
            finished.fulfill()
            return ""
        }
        let profile = StudioProfile(); let layer = StudioLayer(); let context = AppContext(bundleID: "com.google.Chrome", url: "https://youtube.com/watch?v=x")
        let seek = StudioBinding(action: StudioAction(.media, value: "seek", amount: 5))
        let toggle = StudioBinding(action: StudioAction(.media, value: "playPause"))
        func invocation(_ binding: StudioBinding) -> ActionInvocation { ActionInvocation(binding: binding, profile: profile, layer: layer, context: context) }
        executor.execute(invocation(toggle))
        wait(for: [started], timeout: 2)
        executor.execute(invocation(seek)); executor.execute(invocation(seek)); executor.execute(invocation(seek))
        executor.execute(invocation(toggle))
        release.signal()
        wait(for: [finished], timeout: 3)
        lock.lock(); let result = observed; lock.unlock()
        XCTAssertEqual(result.map(\.0), ["playPause", "seek", "playPause"])
        XCTAssertEqual(result[1].1, 15)
    }
    func testCapturedReportsAndReleaseWithoutModifier() {
        let d = DeviceEventDecoder()
        func report(_ id: UInt32, _ bytes: [UInt8]) -> [ControlEvent] { d.decode(RawReport(reportID: id, bytes: bytes, timestamp: 0), layout: [:]) }
        XCTAssertEqual(report(2, [2, 0xe9, 0]), [ControlEvent(.dial, .rotate, delta: 1)])
        XCTAssertEqual(report(2, [2, 0, 0]), [])
        XCTAssertEqual(report(1, [1, 1, 0, 0x19, 0, 0, 0, 0, 0]), [ControlEvent(.leftTop, .down)])
        XCTAssertEqual(report(1, [1, 0, 0, 0x19, 0, 0, 0, 0, 0]), [])
        XCTAssertEqual(report(1, [1, 0, 0, 0, 0, 0, 0, 0, 0]), [ControlEvent(.leftTop, .up)])
        XCTAssertEqual(report(3, [3, 0, 0, 0, 0, 0]), [])
    }
    private func vendor(_ code: String, prefixed: Bool = true) -> RawReport {
        let chars = Array(code); let bytes = stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! }
        return RawReport(reportID: 0xfb, bytes: (prefixed ? [0xfb] : []) + bytes + VendorProtocol.token + Array(repeating: 0, count: 48), timestamp: 0)
    }
    func testVendorReportsAndCalibration() {
        XCTAssertEqual(VendorProtocol.output.count, 65)
        XCTAssertEqual(VendorProtocol.decode(vendor(VendorProtocol.response)), .keepAlive)
        XCTAssertEqual(VendorProtocol.decode(vendor("3edd5f9e876af42c", prefixed: false)), .rotation(1))
        XCTAssertEqual(VendorProtocol.decode(vendor("719b15f1c58517fe")), .pressedRotation(1))
        XCTAssertEqual(VendorProtocol.decode(vendor("014b14c8d0069800")), .pressedRotation(-1))
        let d = DeviceEventDecoder()
        XCTAssertEqual(d.decode(vendor("719b15f1c58517fe"), layout: [:]), [ControlEvent(.dial, .rotate, delta: 1, pressedRotation: true)])
        XCTAssertEqual(d.decode(vendor("014b14c8d0069800"), layout: [:]), [ControlEvent(.dial, .rotate, delta: -1, pressedRotation: true)])
        for (i, codes) in VendorProtocol.codes.enumerated() {
            let down = vendor(codes.0), up = vendor(codes.1)
            XCTAssertEqual(VendorProtocol.decode(down), .button(i + 1, true))
            XCTAssertEqual(d.decode(down, layout: [:]), [])
            XCTAssertEqual(d.decode(down, layout: [String(i+1): .topLeft]), [ControlEvent(.topLeft, .down)])
            XCTAssertEqual(d.decode(up, layout: [String(i+1): .topLeft]), [ControlEvent(.topLeft, .up)])
        }
        XCTAssertNil(VendorProtocol.decode(RawReport(reportID: 0xfb, bytes: [0], timestamp: 0)))
        var broken = vendor(VendorProtocol.response).bytes; broken[9] = 0
        XCTAssertNil(VendorProtocol.decode(RawReport(reportID: 0xfb, bytes: broken, timestamp: 0)))
    }
    func testContextSpecificityAndHostBoundary() {
        let config = StudioConfiguration(profiles: [StudioProfile(name: "特定サイト", bundleID: "com.google.Chrome", host: "example.com"), StudioProfile(name: "その他のアプリ"), StudioProfile(name: "Logic Pro", bundleID: "com.apple.logic10")])
        XCTAssertEqual(LayerEngine.match(config.profiles, AppContext(bundleID: "com.google.Chrome", url: "https://www.example.com/"))?.name, "特定サイト")
        XCTAssertEqual(LayerEngine.match(config.profiles, AppContext(bundleID: "com.google.Chrome", url: "https://notexample.com/"))?.name, "その他のアプリ")
        XCTAssertEqual(LayerEngine.match(config.profiles, AppContext(bundleID: "com.apple.logic10"))?.name, "Logic Pro")
    }
    func testStarterFineAdjustmentIsAHeldLayer() {
        let engine = LayerEngine(StudioConfiguration.starter)
        engine.updateContext(AppContext(bundleID: "com.google.Chrome"))
        engine.handle(ControlEvent(.leftTop, .down))
        XCTAssertEqual(engine.layer?.name, "再生")
        XCTAssertEqual(engine.activeOverlays.map(\.name), ["微調整"])
        engine.handle(ControlEvent(.leftTop, .up))
        XCTAssertTrue(engine.activeOverlays.isEmpty)
    }
    func testNormalLayerDoesNotInheritBaseBindings() {
        var base = StudioLayer(name: "base")
        let other = StudioLayer(name: "other")
        base.bindings = [StudioBinding(name: "base button", control: .topMiddle, gesture: .tap, action: StudioAction(.media, value: "playPause")), StudioBinding(name: "base dial", action: StudioAction(.media, value: "seek"))]
        let e = LayerEngine(StudioConfiguration(profiles: [StudioProfile(pages: [page(base), page(other)])]))
        e.updateContext(AppContext()); e.selectLayer(other.id)
        var fired: [String] = []; e.onAction = { fired.append($0.binding.name) }
        e.handle(ControlEvent(.topMiddle, .down)); e.handle(ControlEvent(.topMiddle, .up)); e.handle(ControlEvent(.dial, .rotate, delta: 1))
        XCTAssertTrue(fired.isEmpty)
        e.selectLayer(base.id); e.handle(ControlEvent(.topMiddle, .down)); e.handle(ControlEvent(.topMiddle, .up))
        XCTAssertEqual(fired, ["base button"])
    }
    func testManualProfileSwitchCycleAndReturnToAutomatic() throws {
        var first = StudioProfile(name: "App A", bundleID: "example.a")
        var second = StudioProfile(name: "App B", bundleID: "example.b")
        var third = StudioProfile(name: "App C", bundleID: "example.c")
        first.pages[0].layers[0].bindings = [StudioBinding(control: .topLeft, gesture: .tap, action: StudioAction(.switchProfile, profile: second.id))]
        second.pages[0].layers[0].bindings = [StudioBinding(control: .topMiddle, gesture: .tap, action: StudioAction(.cycleProfile))]
        third.pages[0].layers[0].bindings = [StudioBinding(control: .topRight, gesture: .tap, action: StudioAction(.automaticProfile))]
        let config = StudioConfiguration(profiles: [first, second, third])
        try config.validate()
        let e = LayerEngine(config)
        func tap(_ control: Control) { e.handle(ControlEvent(control, .down)); e.handle(ControlEvent(control, .up)) }
        e.updateContext(AppContext(bundleID: "example.a")); XCTAssertEqual(e.profileID, first.id)
        tap(.topLeft); XCTAssertEqual(e.profileID, second.id); XCTAssertEqual(e.pinnedProfileID, second.id)
        e.updateContext(AppContext(bundleID: "example.c")); XCTAssertEqual(e.profileID, second.id)
        tap(.topMiddle); XCTAssertEqual(e.profileID, third.id); XCTAssertEqual(e.pinnedProfileID, third.id)
        e.updateContext(AppContext(bundleID: "example.a")); XCTAssertEqual(e.profileID, third.id)
        tap(.topRight); XCTAssertEqual(e.profileID, first.id); XCTAssertNil(e.pinnedProfileID)
        e.updateContext(AppContext(bundleID: "example.b")); XCTAssertEqual(e.profileID, second.id)
    }
    func testChordDoesNotDiscardButtonTapAndMostSpecificWins() {
        let bindings = [StudioBinding(name: "single", control: .leftTop, gesture: .tap), StudioBinding(name: "rotate"), StudioBinding(name: "chord", held: [.leftTop]), StudioBinding(name: "two", held: [.leftTop, .rightTop])]
        let config = StudioConfiguration(profiles: [StudioProfile(pages: [page(StudioLayer(bindings: bindings))])])
        let e = LayerEngine(config); e.updateContext(AppContext()); var fired: [String] = []; e.onAction = { fired.append($0.binding.name) }
        e.handle(ControlEvent(.leftTop, .down)); e.handle(ControlEvent(.rightTop, .down))
        e.handle(ControlEvent(.dial, .rotate, delta: 1)); e.handle(ControlEvent(.rightTop, .up)); e.handle(ControlEvent(.leftTop, .up))
        XCTAssertEqual(fired, ["two", "single"])
        e.handle(ControlEvent(.leftTop, .down)); e.handle(ControlEvent(.leftTop, .up)); XCTAssertEqual(fired, ["two", "single", "single"])
    }
    func testHoldSuppressesTapAndModifiersAreExact() {
        let bindings = [StudioBinding(name: "tap", control: .leftTop, gesture: .tap), StudioBinding(name: "hold", control: .leftTop, gesture: .hold), StudioBinding(name: "shift", modifiers: [.shift])]
        let e = LayerEngine(StudioConfiguration(profiles: [StudioProfile(pages: [page(StudioLayer(bindings: bindings))])])); e.updateContext(AppContext())
        var fired: [String] = []; e.onAction = { fired.append($0.binding.name) }
        e.handle(ControlEvent(.leftTop, .down), now: 1); e.advance(now: 2); e.advance(now: 3); e.handle(ControlEvent(.leftTop, .up), now: 4)
        e.handle(ControlEvent(.dial, .rotate, delta: 1)); e.handle(ControlEvent(.dial, .rotate, delta: 1), modifiers: [.shift])
        XCTAssertEqual(fired, ["hold", "shift"])
    }
    func testButtonReleaseDoesNotTriggerOnAnotherPage() {
        let a = StudioPage(name: "A")
        let b = StudioPage(name: "B", layers: [StudioLayer(bindings: [StudioBinding(name: "tap", control: .topLeft, gesture: .tap)])])
        let engine = LayerEngine(StudioConfiguration(profiles: [StudioProfile(pages: [a, b])]))
        engine.updateContext(AppContext()); var fired = false; engine.onAction = { _ in fired = true }
        engine.handle(ControlEvent(.topLeft, .down)); engine.selectLayer(b.id); engine.handle(ControlEvent(.topLeft, .up))
        XCTAssertFalse(fired)
    }
    func testButtonStreamUsesPressOriginAcrossPageChange() throws {
        let overlay = StudioLayer(name: "Overlay")
        var base = StudioLayer(name: "A")
        base.bindings = [
            StudioBinding(name: "start", control: .leftTop, gesture: .press, action: StudioAction(.overlayHold, layer: overlay.id)),
            StudioBinding(name: "release A", control: .leftTop, gesture: .release, action: StudioAction(.shortcut, value: "a")),
            StudioBinding(name: "tap A", control: .leftTop, gesture: .tap, action: StudioAction(.shortcut, value: "b"))
        ]
        let a = StudioPage(name: "A", layers: [base, overlay])
        let b = StudioPage(name: "B", layers: [StudioLayer(bindings: [
            StudioBinding(name: "nested B", control: .topRight, gesture: .tap, action: StudioAction(.shortcut, value: "c")),
            StudioBinding(name: "release B", control: .leftTop, gesture: .release, action: StudioAction(.shortcut, value: "d"))
        ])])
        let config = StudioConfiguration(profiles: [StudioProfile(pages: [a, b])]); try config.validate()
        let engine = LayerEngine(config); engine.updateContext(AppContext()); var calls: [String] = []
        engine.onAction = { calls.append($0.binding.name) }
        engine.handle(ControlEvent(.leftTop, .down), now: 1)
        XCTAssertEqual(engine.activeOverlays.map(\.id), [overlay.id])
        engine.selectLayer(b.id)
        engine.handle(ControlEvent(.topRight, .down), now: 1.1); engine.handle(ControlEvent(.topRight, .up), now: 1.2)
        engine.handle(ControlEvent(.leftTop, .up), now: 1.3)
        XCTAssertEqual(calls, ["start", "nested B", "release A", "tap A"])
        XCTAssertEqual(engine.layer?.id, b.id)
        XCTAssertTrue(engine.activeOverlays.isEmpty)
        engine.selectLayer(a.id); XCTAssertTrue(engine.activeOverlays.isEmpty)
    }
    func testAllButtonEventsAndLongReleaseOrder() throws {
        let bindings = [
            StudioBinding(name: "press", control: .topLeft, gesture: .press),
            StudioBinding(name: "hold", control: .topLeft, gesture: .hold),
            StudioBinding(name: "release", control: .topLeft, gesture: .release),
            StudioBinding(name: "short", control: .topLeft, gesture: .tap),
            StudioBinding(name: "long release", control: .topLeft, gesture: .holdRelease)
        ]
        let config = StudioConfiguration(profiles: [StudioProfile(pages: [StudioPage(layers: [StudioLayer(bindings: bindings)])])]); try config.validate()
        let engine = LayerEngine(config); engine.updateContext(AppContext()); var calls: [String] = []
        engine.onAction = { calls.append($0.binding.name) }
        engine.handle(ControlEvent(.topLeft, .down), now: 1); engine.handle(ControlEvent(.topLeft, .up), now: 1.1)
        XCTAssertEqual(calls, ["press", "release", "short"])
        calls.removeAll()
        engine.handle(ControlEvent(.topLeft, .down), now: 2); engine.advance(now: 2.6); engine.handle(ControlEvent(.topLeft, .up), now: 2.7)
        XCTAssertEqual(calls, ["press", "hold", "release", "long release"])
        calls.removeAll()
        engine.handle(ControlEvent(.topLeft, .down), now: 3); engine.handle(ControlEvent(.topLeft, .up), now: 3.6)
        XCTAssertEqual(calls, ["press", "hold", "release", "long release"])
    }
    func testContinuousActionsCanStartOnHoldAndEndByOwningPress() throws {
        let one = StudioLayer(name: "One"), two = StudioLayer(name: "Two")
        var binding = StudioBinding(name: "hold", control: .topLeft, gesture: .hold, action: StudioAction(.overlayHold, layer: one.id))
        binding.steps = [ActionStep(action: StudioAction(.overlayHold, layer: two.id))]
        let base = StudioLayer(name: "Base", bindings: [binding])
        let config = StudioConfiguration(profiles: [StudioProfile(pages: [StudioPage(layers: [base, one, two])])]); try config.validate()
        let engine = LayerEngine(config); engine.updateContext(AppContext()); var invocation: ActionInvocation?
        engine.onAction = { invocation = $0 }
        engine.handle(ControlEvent(.topLeft, .down), now: 1); engine.advance(now: 1.5)
        let captured = try XCTUnwrap(invocation)
        XCTAssertTrue(engine.applyStateAction(binding.action, control: .topLeft, pressID: captured.pressID))
        XCTAssertTrue(engine.applyStateAction(binding.steps![0].action, control: .topLeft, pressID: captured.pressID))
        XCTAssertEqual(engine.activeOverlays.map(\.id), [one.id, two.id])
        engine.handle(ControlEvent(.topLeft, .up), now: 1.6)
        XCTAssertTrue(engine.activeOverlays.isEmpty)
        engine.handle(ControlEvent(.topLeft, .down), now: 2)
        XCTAssertFalse(engine.applyStateAction(binding.action, control: .topLeft, pressID: captured.pressID))
        XCTAssertTrue(engine.activeOverlays.isEmpty)
    }
    func testContinuousSequenceRejectedForReleaseGestures() {
        let overlay = StudioLayer(name: "Overlay")
        for gesture in [GestureKind.tap, .release, .holdRelease] {
            var binding = StudioBinding(control: .leftTop, gesture: gesture, action: StudioAction(.shortcut, value: "a"))
            binding.steps = [ActionStep(action: StudioAction(.overlayHold, layer: overlay.id))]
            let config = StudioConfiguration(profiles: [StudioProfile(pages: [StudioPage(layers: [StudioLayer(bindings: [binding]), overlay])])])
            XCTAssertThrowsError(try config.validate())
        }
    }
    func testValidationAndAtomicRoundTrip() throws {
        var config = StudioConfiguration.starter
        config.profiles[0].iconData = Data([0, 1, 2, 255])
        var recordEnd = StudioAction(.midi, value: "recordEnd")
        recordEnd.keyCommand = "cmd+shift+r"
        config.profiles[0].pages[0].layers[0].bindings.append(StudioBinding(name: "録音停止", control: .rightTop, gesture: .tap, action: recordEnd))
        try config.validate()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json"); try config.save(to: url)
        XCTAssertEqual(try StudioConfiguration.load(from: url), config)
        config.profiles[0].pages[0].layers[0].bindings.append(config.profiles[0].pages[0].layers[0].bindings[0])
        XCTAssertThrowsError(try config.save(to: url))
        XCTAssertNotEqual(try StudioConfiguration.load(from: url), config)
        config = .starter; config.vendorLayout = ["1": .topLeft, "2": .topLeft]; XCTAssertThrowsError(try config.validate())
        config = .starter; config.profiles[0].pages[0].layers[0].bindings[0].action = StudioAction(.switchLayer, layer: UUID()); XCTAssertThrowsError(try config.validate())
    }
    func testProcessOutputErrorsTimeoutAndQuoting() throws {
        XCTAssertEqual(try ProcessRunner.checked("/bin/zsh", ["-c", "printf '%s' \"$DIAL_AMOUNT\""], environment: ["DIAL_AMOUNT": "1.25"]), "1.25")
        XCTAssertThrowsError(try ProcessRunner.checked("/bin/zsh", ["-c", "print -u2 failure; exit 3"]))
        let start = Date(); XCTAssertThrowsError(try ProcessRunner.run("/bin/sleep", ["5"], timeout: 0.1)); XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let text = "literal 'quote' $HOME `hostname`\n日本語"
        XCTAssertEqual(try ProcessRunner.checked("/bin/zsh", ["-c", "printf '%s' " + ProcessRunner.shellQuote(text)]), text)
    }
    func testMCURelativeEncoding() {
        XCTAssertEqual(MCU.Button.playStop.rawValue, 0x66)
        XCTAssertEqual(Set(MCU.controls.map(\.id)).count, 113)
        XCTAssertEqual(MCU.controls.first { $0.id == 0x5f }?.name, "録音")
        XCTAssertEqual(MCU.faderMessages(8, value: 16383), [[0x90, 0x70, 127], [0xe8, 127, 127], [0x90, 0x70, 0]])
        XCTAssertEqual(LogicRecordingState.recordButton(recording: true), .stop)
        XCTAssertEqual(LogicRecordingState.recordButton(recording: false), .record)
        XCTAssertEqual(MCU.relativeCC(0x3c, ticks: 1), [0xb0, 0x3c, 1])
        XCTAssertEqual(MCU.relativeCC(0x3c, ticks: -1), [0xb0, 0x3c, 0x41])
        XCTAssertEqual(MCU.relativeCC(0x3c, ticks: 100), [0xb0, 0x3c, 63])
    }
}

extension StudioTests {
    func testTitleConditionWinsAndReturnsToAppDefault() {
        let normal = StudioProfile(name: "normal", bundleID: "example.app")
        var editor = StudioProfile(name: "editor", bundleID: "example.app"); editor.titleContains = "Piano Roll"
        let profiles = [normal, editor]
        XCTAssertEqual(LayerEngine.match(profiles, AppContext(bundleID: "example.app", title: "Song — piano roll"))?.id, editor.id)
        XCTAssertEqual(LayerEngine.match(profiles, AppContext(bundleID: "example.app", title: "Mixer"))?.id, normal.id)
    }
    func testReloadClearsHeldAndRemovedLayer() {
        var config = StudioConfiguration.starter; let e = LayerEngine(config)
        e.updateContext(AppContext(bundleID: "com.google.Chrome"))
        e.handle(ControlEvent(.leftTop, .down)); XCTAssertEqual(e.activeOverlays.map(\.name), ["微調整"])
        config.profiles[0].pages[0].layers.removeLast()
        config.profiles[0].pages[0].layers[0].bindings.removeAll { $0.action.type == .overlayHold }
        e.reload(config); XCTAssertTrue(e.pressed.isEmpty); XCTAssertTrue(e.activeOverlays.isEmpty)
    }
    func testProcessOutputLimitAndChildTimeout() throws {
        let result = try ProcessRunner.checked("/bin/zsh", ["-c", "printf 'x%.0s' {1..100000}"])
        XCTAssertEqual(result.utf8.count, 65536)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let script = "(sleep 0.5; touch " + ProcessRunner.shellQuote(file.path) + ") & wait"
        XCTAssertThrowsError(try ProcessRunner.checked("/bin/zsh", ["-c", script], timeout: 0.05))
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testExtremeRotationDoesNotOverflow() {
        let e = LayerEngine(StudioConfiguration(profiles: [StudioProfile(pages: [page(StudioLayer(bindings: [StudioBinding(gesture: .counterclockwise)]))])]))
        e.updateContext(AppContext()); var count = 0; e.onAction = { _ in count += 1 }
        e.handle(ControlEvent(.dial, .rotate, delta: Int.min)); XCTAssertEqual(count, 64)
        XCTAssertEqual(MCU.relativeCC(0x3c, ticks: Int.min), [0xb0, 0x3c, 0x7f])
    }
}

extension StudioTests {
    func testButtonDropPrefersPressThenFreeGesturesWithoutOverwriting() throws {
        var config = StudioConfiguration(profiles: [StudioProfile()])
        let p = config.profiles[0].id, l = config.profiles[0].pages[0].layers[0].id
        let template = try XCTUnwrap(ActionTemplate.all.first { $0.id == "system.shortcut" })
        let first = try config.assign(template, profileID: p, layerID: l, control: .topLeft)
        XCTAssertEqual(config.profiles[0].pages[0].layers[0].bindings.first { $0.id == first.bindingID }?.gesture, .press)
        let second = try config.assign(template, profileID: p, layerID: l, control: .topLeft)
        XCTAssertFalse(second.replaced)
        XCTAssertEqual(config.profiles[0].pages[0].layers[0].bindings.first { $0.id == second.bindingID }?.gesture, .tap)
        for _ in 0..<3 { _ = try config.assign(template, profileID: p, layerID: l, control: .topLeft) }
        let before = config
        XCTAssertThrowsError(try config.assign(template, profileID: p, layerID: l, control: .topLeft))
        XCTAssertEqual(config, before)
        let replaced = try config.assign(template, profileID: p, layerID: l, control: .topLeft, gesture: .tap)
        XCTAssertTrue(replaced.replaced)
        let knob = try config.assign(template, profileID: p, layerID: l, control: .knob)
        XCTAssertEqual(config.profiles[0].pages[0].layers[0].bindings.first { $0.id == knob.bindingID }?.gesture, .press)
        try config.validate()
    }

    func testContinuousDropUsesNextAvailableCompatibleGesture() throws {
        let overlay = StudioLayer(name: "Overlay")
        var base = StudioLayer()
        base.bindings = [StudioBinding(control: .topLeft, gesture: .press, action: StudioAction(.shortcut, value: "a"))]
        var config = StudioConfiguration(profiles: [StudioProfile(pages: [StudioPage(layers: [base, overlay])])])
        let p = config.profiles[0].id
        let template = try XCTUnwrap(ActionTemplate.all.first { $0.id == "overlay.hold" })
        let result = try config.assign(template, profileID: p, layerID: base.id, control: .topLeft)
        XCTAssertFalse(result.replaced)
        XCTAssertEqual(config.profiles[0].pages[0].layers[0].bindings.first { $0.id == result.bindingID }?.gesture, .hold)
        try config.validate()
    }

    func testDropCreatesDirectionalBindingAndPreservesChords() throws {
        var config = StudioConfiguration.starter
        let p = config.profiles[0].id, l = config.profiles[0].pages[0].layers[0].id
        config.profiles[0].pages[0].layers[0].bindings.append(StudioBinding(name: "chord", gesture: .counterclockwise, held: [.rightTop], action: StudioAction(.media, value: "seek", amount: -0.1)))
        let originalCount = config.profiles[0].pages[0].layers[0].bindings.count
        let originalClockwise = config.profiles[0].pages[0].layers[0].bindings.first { $0.gesture == .clockwise }!
        let result = try config.assign(ActionTemplate.all.first { $0.id == "system.seek" }!, profileID: p, layerID: l, control: .dial, gesture: .counterclockwise)
        XCTAssertTrue(result.replaced)
        let updated = config.profiles[0].pages[0].layers[0].bindings.first { $0.id == result.bindingID }!
        XCTAssertEqual(updated.action.value, "seek"); XCTAssertEqual(updated.action.amount, -5)
        XCTAssertEqual(config.profiles[0].pages[0].layers[0].bindings.count, originalCount)
        XCTAssertEqual(config.profiles[0].pages[0].layers[0].bindings.first { $0.id == originalClockwise.id }, originalClockwise)
        XCTAssertEqual(config.profiles[0].pages[0].layers[0].bindings.last?.name, "chord")
        try config.validate()
    }
    func testDropMomentaryUsesPressAndRejectsDial() throws {
        var config = StudioConfiguration.starter
        let p = config.profiles[0].id, l = config.profiles[0].pages[0].layers[0].id
        let template = ActionTemplate.all.first { $0.id == "overlay.hold" }!
        let result = try config.assign(template, profileID: p, layerID: l, control: .rightBottom)
        XCTAssertFalse(result.replaced)
        let binding = config.profiles[0].pages[0].layers[0].bindings.first { $0.id == result.bindingID }!
        XCTAssertEqual(binding.gesture, .press); XCTAssertNotEqual(binding.action.targetLayer, l)
        let previous = config
        XCTAssertThrowsError(try config.assign(template, profileID: p, layerID: l, control: .dial))
        XCTAssertEqual(config, previous); try config.validate()
    }
    func testAllPaletteTemplatesProduceValidConfiguration() throws {
        for template in ActionTemplate.all {
            var config = StudioConfiguration.starter
            let overlay = StudioLayer(name: "Overlay")
            config.profiles[0].pages[0].layers.append(overlay)
            _ = try config.assign(template, profileID: config.profiles[0].id, layerID: config.profiles[0].pages[0].layers[0].id, control: .rightBottom)
            try config.validate()
            XCTAssertEqual(ActionTemplate.from(payload: template.payload)?.id, template.id)
        }
        XCTAssertNil(ActionTemplate.from(payload: "arbitrary text"))
    }

    func testOverlaysResolveTopDownAndReleaseByOwner() throws {
        var low = StudioLayer(name: "Low")
        var high = StudioLayer(name: "High")
        low.bindings = [StudioBinding(name: "low", action: StudioAction(.shortcut, value: "a"))]
        high.bindings = [StudioBinding(name: "high", action: StudioAction(.shortcut, value: "b")),
                         StudioBinding(name: "block", control: .topMiddle, gesture: .tap, action: StudioAction(.block))]
        let page = StudioLayer(name: "Page", bindings: [
            StudioBinding(name: "base", action: StudioAction(.shortcut, value: "c")),
            StudioBinding(name: "play", control: .topMiddle, gesture: .press, action: StudioAction(.shortcut, value: "space")),
            StudioBinding(name: "low hold", control: .leftTop, gesture: .press, action: StudioAction(.overlayHold, layer: low.id)),
            StudioBinding(name: "high hold", control: .rightTop, gesture: .press, action: StudioAction(.overlayHold, layer: high.id))])
        let config = StudioConfiguration(profiles: [StudioProfile(pages: [StudioPage(name: "Page", layers: [page, low, high])])])
        try config.validate()
        let engine = LayerEngine(config); engine.updateContext(AppContext())
        var calls: [String] = []; engine.onAction = { calls.append($0.binding.name) }
        engine.handle(ControlEvent(.leftTop, .down))
        engine.handle(ControlEvent(.rightTop, .down))
        XCTAssertEqual(engine.activeOverlays.map(\.id), [low.id, high.id])
        engine.handle(ControlEvent(.dial, .rotate, delta: 1))
        engine.handle(ControlEvent(.topMiddle, .down)); engine.handle(ControlEvent(.topMiddle, .up))
        XCTAssertEqual(calls.last, "high") // block suppresses the page's press action
        engine.handle(ControlEvent(.leftTop, .up)) // lower layer released first
        XCTAssertEqual(engine.activeOverlays.map(\.id), [high.id])
        engine.handle(ControlEvent(.dial, .rotate, delta: 1)); XCTAssertEqual(calls.last, "high")
        engine.handle(ControlEvent(.rightTop, .up))
        XCTAssertTrue(engine.activeOverlays.isEmpty)
        engine.handle(ControlEvent(.dial, .rotate, delta: 1)); XCTAssertEqual(calls.last, "base")
        engine.handle(ControlEvent(.topMiddle, .down)); XCTAssertEqual(calls.last, "play")
    }

    func testOverlayPriorityIsIndependentOfActivationOrderAndMultipleOwners() throws {
        var low = StudioLayer(name: "Low")
        var high = StudioLayer(name: "High")
        low.bindings = [StudioBinding(name: "low", action: StudioAction(.shortcut, value: "a"))]
        high.bindings = [StudioBinding(name: "high", action: StudioAction(.shortcut, value: "b"))]
        let page = StudioLayer(bindings: [
            StudioBinding(control: .leftTop, gesture: .press, action: StudioAction(.overlayHold, layer: high.id)),
            StudioBinding(control: .rightTop, gesture: .press, action: StudioAction(.overlayHold, layer: low.id)),
            StudioBinding(control: .rightBottom, gesture: .press, action: StudioAction(.overlayHold, layer: high.id))])
        let engine = LayerEngine(StudioConfiguration(profiles: [StudioProfile(pages: [StudioPage(name: "Page", layers: [page, low, high])])]))
        engine.updateContext(AppContext()); var result = ""; engine.onAction = { result = $0.binding.name }
        engine.handle(ControlEvent(.leftTop, .down)); engine.handle(ControlEvent(.rightTop, .down)); engine.handle(ControlEvent(.rightBottom, .down))
        engine.handle(ControlEvent(.dial, .rotate, delta: 1)); XCTAssertEqual(result, "high")
        engine.handle(ControlEvent(.leftTop, .up)); XCTAssertEqual(engine.activeOverlays.map(\.id), [low.id, high.id])
        engine.handle(ControlEvent(.rightBottom, .up)); XCTAssertEqual(engine.activeOverlays.map(\.id), [low.id])
        engine.handle(ControlEvent(.dial, .rotate, delta: 1)); XCTAssertEqual(result, "low")
    }

    func testToggledUpperLayerBeatsHeldLowerLayerForButtonTap() throws {
        var lower = StudioLayer(name: "Lower")
        var upper = StudioLayer(name: "Upper")
        lower.bindings = [StudioBinding(name: "lower", control: .topLeft, gesture: .tap, action: StudioAction(.shortcut, value: "cmd+z"))]
        upper.bindings = [StudioBinding(name: "upper", control: .topLeft, gesture: .tap, action: StudioAction(.shortcut, value: "cmd+t"))]
        let bottom = StudioLayer(bindings: [
            StudioBinding(control: .topRight, gesture: .tap, action: StudioAction(.overlayToggle, layer: upper.id)),
            StudioBinding(control: .leftBottom, gesture: .press, action: StudioAction(.overlayHold, layer: lower.id))
        ])
        let engine = LayerEngine(StudioConfiguration(profiles: [StudioProfile(pages: [StudioPage(layers: [bottom, lower, upper])])]))
        engine.updateContext(AppContext())
        var calls: [String] = []; engine.onAction = { calls.append($0.binding.name) }
        engine.handle(ControlEvent(.topRight, .down), now: 0)
        engine.handle(ControlEvent(.topRight, .up), now: 0.1)
        engine.handle(ControlEvent(.leftBottom, .down), now: 0.2)
        engine.handle(ControlEvent(.topLeft, .down), now: 0.3)
        engine.handle(ControlEvent(.topLeft, .up), now: 0.4)
        XCTAssertEqual(engine.activeOverlays.map(\.id), [lower.id, upper.id])
        XCTAssertEqual(calls.last, "upper")
    }

    func testOverlayIsScopedToPageAndIsPrunedOnReload() throws {
        let pageA = StudioLayer(name: "A"), pageB = StudioLayer(name: "B")
        let overlay = StudioLayer(name: "Overlay")
        var a = page(pageA); a.layers.append(overlay)
        var config = StudioConfiguration(profiles: [StudioProfile(pages: [a, page(pageB)])])
        let engine = LayerEngine(config); engine.updateContext(AppContext())
        XCTAssertTrue(engine.applyStateAction(StudioAction(.overlayToggle, layer: overlay.id), control: .topLeft))
        engine.selectLayer(pageB.id)
        XCTAssertEqual(engine.layer?.id, pageB.id)
        XCTAssertTrue(engine.activeOverlays.isEmpty)
        engine.selectLayer(pageA.id)
        XCTAssertEqual(engine.activeOverlays.map(\.id), [overlay.id])
        XCTAssertTrue(engine.applyStateAction(StudioAction(.overlayToggle, layer: overlay.id), control: .topLeft))
        engine.selectLayer(pageB.id)
        XCTAssertTrue(engine.activeOverlays.isEmpty)
        XCTAssertFalse(engine.applyStateAction(StudioAction(.overlayToggle, layer: overlay.id), control: .topLeft))
        engine.selectLayer(pageA.id)
        XCTAssertTrue(engine.applyStateAction(StudioAction(.overlayToggle, layer: overlay.id), control: .topLeft))
        engine.selectLayer(pageB.id)
        config.profiles[0].pages[0].layers.removeAll { $0.id == overlay.id }
        engine.reload(config)
        XCTAssertTrue(engine.activeOverlays.isEmpty)
        XCTAssertEqual(engine.layer?.id, pageB.id)
    }

    func testPressedRotationIsAnIndependentGesture() throws {
        let firstLayer = StudioLayer(name: "Base", bindings: [
            StudioBinding(name: "next", gesture: .pressedClockwise, action: StudioAction(.cycleLayer)),
            StudioBinding(name: "normal", gesture: .clockwise, action: StudioAction(.shortcut, value: "a")),
            StudioBinding(name: "press", control: .knob, gesture: .press, action: StudioAction(.shortcut, value: "b"))
        ])
        let first = StudioPage(name: "First", layers: [firstLayer]), second = StudioPage(name: "Second")
        let config = StudioConfiguration(profiles: [StudioProfile(pages: [first, second])])
        try config.validate()
        let engine = LayerEngine(config); engine.updateContext(AppContext()); var calls: [String] = []
        engine.onAction = { calls.append($0.binding.name) }
        let decoder = DeviceEventDecoder()
        for event in decoder.decode(vendor("719b15f1c58517fe"), layout: [:]) { engine.handle(event) }
        XCTAssertEqual(engine.layer?.id, second.id)
        XCTAssertEqual(calls, ["next"])
        XCTAssertTrue(engine.pressed.isEmpty)
        engine.selectLayer(first.id)
        engine.handle(ControlEvent(.dial, .rotate, delta: 1))
        XCTAssertEqual(calls, ["next", "normal"])
    }
    func testPressedRotationCanBeAssignedAndPreservesDirection() throws {
        var config = StudioConfiguration.starter
        let profile = config.profiles[0], layer = profile.pages[0].layers[0]
        let template = try XCTUnwrap(ActionTemplate.all.first { $0.id == "system.volume" })
        let change = try config.assign(template, profileID: profile.id, layerID: layer.id, control: .dial, gesture: .pressedCounterclockwise)
        let binding = try XCTUnwrap(config.profiles[0].pages[0].layers[0].bindings.first { $0.id == change.bindingID })
        XCTAssertEqual(binding.gesture, .pressedCounterclockwise)
        XCTAssertEqual(binding.action.amount, -1)
        try config.validate()
    }
    func testPagesAndLayersRoundTrip() throws {
        var config = StudioConfiguration.starter
        let overlay = StudioLayer(name: "Overlay")
        config.profiles[0].pages[0].layers.append(overlay)
        let decoded = try JSONDecoder().decode(StudioConfiguration.self, from: JSONEncoder().encode(config))
        try decoded.validate()
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.profiles[0].pages[0].layers.last?.id, overlay.id)
        XCTAssertFalse(decoded.profiles[1].pages[0].layers.contains { $0.id == overlay.id })
    }
    func testOverlayTargetCannotReferToAnotherPage() throws {
        var bottom = StudioLayer(name: "Bottom")
        let foreign = StudioLayer(name: "Foreign")
        bottom.bindings = [StudioBinding(control: .leftTop, gesture: .press, action: StudioAction(.overlayHold, layer: foreign.id))]
        let config = StudioConfiguration(profiles: [StudioProfile(pages: [StudioPage(name: "A", layers: [bottom]), StudioPage(name: "B", layers: [StudioLayer(), foreign])])])
        XCTAssertThrowsError(try config.validate())
    }
    func testOldSettingsAreNotMigrated() throws {
        let encoded = try JSONEncoder().encode(StudioConfiguration.starter)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var profiles = try XCTUnwrap(root["profiles"] as? [[String: Any]])
        let pages = try XCTUnwrap(profiles[0].removeValue(forKey: "pages") as? [[String: Any]])
        profiles[0]["layers"] = pages.flatMap { ($0["layers"] as? [[String: Any]]) ?? [] }
        root["version"] = 2; root["profiles"] = profiles
        let data = try JSONSerialization.data(withJSONObject: root)
        XCTAssertThrowsError(try JSONDecoder().decode(StudioConfiguration.self, from: data))
    }

}
