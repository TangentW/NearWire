import XCTest

@testable import NearWire
@testable import NearWireUI

@MainActor
final class NearWireUIOperationCoordinatorTests: XCTestCase {
  func testConnectIsDeduplicatedAndPhaseIsSharedAcrossSubscribers() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let first = coordinator.subscribe(controller: controller)
    let second = coordinator.subscribe(controller: controller)
    XCTAssertEqual(first.initialPhase, .idle)
    XCTAssertEqual(second.initialPhase, .idle)

    let token = coordinator.connect(controller: controller, code: "PAIR") { _, _ in }
    XCTAssertNotNil(token)
    XCTAssertNil(coordinator.connect(controller: controller, code: "DUPLICATE") { _, _ in })
    await NearWireUITestWait.until { controller.pendingConnectCount == 1 }
    XCTAssertEqual(controller.recordedConnectCodes, ["PAIR"])
    XCTAssertEqual(coordinator.phase(for: controller), .connecting)
    XCTAssertEqual(coordinator.liveTaskCounts(for: controller).connect, 1)

    controller.finishNextConnect()
    await NearWireUITestWait.until { coordinator.phase(for: controller) == .idle }
    coordinator.unsubscribe(controller: controller, token: first.token)
    coordinator.unsubscribe(controller: controller, token: second.token)
    XCTAssertEqual(coordinator.entryCount, 0)
  }

  func testNaturalStreamTerminationRemovesOnlyItsExactSubscriber() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let first = coordinator.subscribe(controller: controller)
    let second = coordinator.subscribe(controller: controller)
    let consumer = Task {
      for await _ in first.stream {}
    }
    await Task.yield()
    consumer.cancel()
    await NearWireUITestWait.until { coordinator.subscriberCount(for: controller) == 1 }
    coordinator.unsubscribe(controller: controller, token: second.token)
    await NearWireUITestWait.until { coordinator.entryCount == 0 }
  }

  func testPhasePublicationRacesNaturalTerminationWithoutRetention() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    for iteration in 0..<25 {
      let registration = coordinator.subscribe(controller: controller)
      let consumer = Task {
        for await _ in registration.stream {}
      }
      await Task.yield()
      let cancellation = Task.detached { consumer.cancel() }
      _ = coordinator.connect(controller: controller, code: "PAIR-\(iteration)") { _, _ in }
      await cancellation.value
      await NearWireUITestWait.until { controller.pendingConnectCount == 1 }
      controller.finishNextConnect()
      await NearWireUITestWait.until { coordinator.entryCount == 0 }
    }
  }

  func testCancelStartsDisconnectAndWaitsWhenConnectFinishesFirst() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let registration = coordinator.subscribe(controller: controller)
    _ = coordinator.connect(controller: controller, code: "A") { _, _ in }
    await NearWireUITestWait.until { controller.pendingConnectCount == 1 }

    coordinator.disconnect(controller: controller)
    await NearWireUITestWait.until { controller.pendingDisconnectCount == 1 }
    XCTAssertEqual(coordinator.phase(for: controller), .disconnecting)
    controller.finishNextConnect()
    await Task.yield()
    XCTAssertEqual(coordinator.phase(for: controller), .disconnecting)
    XCTAssertEqual(coordinator.liveTaskCounts(for: controller).disconnect, 1)

    controller.finishNextDisconnect()
    await NearWireUITestWait.until { coordinator.phase(for: controller) == .idle }
    coordinator.unsubscribe(controller: controller, token: registration.token)
    XCTAssertEqual(coordinator.entryCount, 0)
  }

  func testCancelWaitsWhenDisconnectFinishesFirst() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let registration = coordinator.subscribe(controller: controller)
    _ = coordinator.connect(controller: controller, code: "A") { _, _ in }
    await NearWireUITestWait.until { controller.pendingConnectCount == 1 }

    coordinator.disconnect(controller: controller)
    await NearWireUITestWait.until { controller.pendingDisconnectCount == 1 }
    controller.finishNextDisconnect()
    await Task.yield()
    XCTAssertEqual(coordinator.phase(for: controller), .disconnecting)
    XCTAssertEqual(coordinator.liveTaskCounts(for: controller).connect, 1)

    controller.finishNextConnect()
    await NearWireUITestWait.until { coordinator.phase(for: controller) == .idle }
    coordinator.unsubscribe(controller: controller, token: registration.token)
    XCTAssertEqual(coordinator.entryCount, 0)
  }

  func testDisappearanceCancelsConnectWithoutStartingDisconnect() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let registration = coordinator.subscribe(controller: controller)
    let token = coordinator.connect(controller: controller, code: "A") { _, _ in }
    XCTAssertNotNil(token)
    await NearWireUITestWait.until { controller.pendingConnectCount == 1 }

    coordinator.cancelConnectForDisappearance(controller: controller, token: token!)
    XCTAssertEqual(coordinator.phase(for: controller), .cancelling)
    XCTAssertEqual(controller.pendingDisconnectCount, 0)
    XCTAssertEqual(controller.cancellationCount, 1)

    coordinator.unsubscribe(controller: controller, token: registration.token)
    controller.finishNextConnect()
    await NearWireUITestWait.until { coordinator.entryCount == 0 }
  }

  func testCancellationHandlerCanReenterStorageWithoutDeadlock() async {
    weak var weakController: NearWireUIFakeController?
    weak var weakCoordinator: NearWireUIOperationCoordinator?
    do {
      let controller = NearWireUIFakeController()
      let coordinator = NearWireUIOperationCoordinator()
      weakController = controller
      weakCoordinator = coordinator
      let registration = coordinator.subscribe(controller: controller)
      let token = coordinator.connect(controller: controller, code: "PAIR") { _, _ in }
      XCTAssertNotNil(token)
      await NearWireUITestWait.until { controller.pendingConnectCount == 1 }
      controller.setConnectCancellationObserver { [controller, coordinator] in
        coordinator.releaseModel(
          controller: controller,
          registrationToken: nil,
          operationToken: nil
        )
      }

      coordinator.cancelConnectForDisappearance(controller: controller, token: token!)
      XCTAssertEqual(coordinator.phase(for: controller), .cancelling)
      XCTAssertEqual(controller.cancellationCount, 1)
      coordinator.unsubscribe(controller: controller, token: registration.token)
      controller.finishNextConnect()
      await NearWireUITestWait.until { coordinator.entryCount == 0 }
      controller.setConnectCancellationObserver(nil)
    }
    XCTAssertNil(weakController)
    XCTAssertNil(weakCoordinator)
  }

  func testReverseCancellingDeliveryConvergesToCurrentDisconnectingPhase() async {
    let controller = NearWireUIFakeController()
    let hook = NearWireUIBlockingDeliveryHook(blockedPhase: .cancelling)
    let coordinator = NearWireUIOperationCoordinator { [hook] phase in hook(phase) }
    let model = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    model.start()
    await NearWireUITestWait.until { model.status != nil }

    let token = coordinator.connect(controller: controller, code: "PAIR") { _, _ in }
    XCTAssertNotNil(token)
    await NearWireUITestWait.until {
      model.operationPhase == .connecting && controller.pendingConnectCount == 1
    }

    let releaseTask = Task.detached { [controller, coordinator, token] in
      coordinator.releaseModel(
        controller: controller,
        registrationToken: nil,
        operationToken: token
      )
    }
    await NearWireUITestWait.until { hook.didReachBlockedPhase }

    coordinator.disconnect(controller: controller)
    await NearWireUITestWait.until {
      model.operationPhase == .disconnecting && controller.pendingDisconnectCount == 1
    }
    hook.resume()
    await releaseTask.value
    await NearWireUITestWait.until {
      model.operationPhase == coordinator.phase(for: controller)
    }
    XCTAssertEqual(model.operationPhase, .disconnecting)

    controller.finishNextConnect()
    await NearWireUITestWait.until { model.operationPhase == .disconnecting }
    controller.finishNextDisconnect()
    await NearWireUITestWait.until { model.operationPhase == .idle }
    model.stop()
  }

  func testRepeatedDisconnectJoinsOneFailClosedTask() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let first = coordinator.subscribe(controller: controller)
    coordinator.disconnect(controller: controller)
    coordinator.disconnect(controller: controller)
    await NearWireUITestWait.until { controller.pendingDisconnectCount == 1 }
    XCTAssertEqual(coordinator.phase(for: controller), .disconnecting)
    XCTAssertEqual(coordinator.liveTaskCounts(for: controller).disconnect, 1)

    let second = coordinator.subscribe(controller: controller)
    XCTAssertEqual(second.initialPhase, .disconnecting)
    coordinator.unsubscribe(controller: controller, token: first.token)
    XCTAssertEqual(coordinator.subscriberCount(for: controller), 1)
    controller.finishNextDisconnect()
    await NearWireUITestWait.until { coordinator.phase(for: controller) == .idle }
    coordinator.unsubscribe(controller: controller, token: second.token)
    XCTAssertEqual(coordinator.entryCount, 0)
  }

  func testEveryOwnershipPreflightErrorOffersReset() {
    let codes: [NearWireError.Code] = [
      .connectionInProgress,
      .alreadyConnected,
      .connectionSuspended,
      .connectionIntentExists,
      .anotherConnectionIsActive,
    ]
    for code in codes {
      let outcome = NearWireUIOperationCoordinator.connectOutcome(
        for: NearWireError(code: code, message: "Safe ownership message.")
      )
      XCTAssertEqual(
        outcome,
        .failure(
          NearWireUIActionError(message: "Safe ownership message.", offersReset: true)
        )
      )
    }
  }

  func testCoordinatorReleasesControllerAfterExactCompletionAndUnsubscribe() async {
    var controller: NearWireUIFakeController? = NearWireUIFakeController()
    weak let weakController = controller
    let coordinator = NearWireUIOperationCoordinator()
    let registration = coordinator.subscribe(controller: controller!)
    _ = coordinator.connect(controller: controller!, code: "PAIR") { _, _ in }
    await NearWireUITestWait.until { controller?.pendingConnectCount == 1 }

    controller?.finishNextConnect()
    await NearWireUITestWait.until { coordinator.phase(for: controller!) == .idle }
    coordinator.unsubscribe(controller: controller!, token: registration.token)
    controller = nil
    await NearWireUITestWait.until { weakController == nil }
    XCTAssertEqual(coordinator.entryCount, 0)
  }
}
