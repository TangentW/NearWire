import XCTest

@testable import NearWire
@testable import NearWireUI

@MainActor
final class NearWireUIModelTests: XCTestCase {
  func testConstructionStartsNoObservationOrOperation() {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    _ = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    XCTAssertEqual(controller.statusSubscriberCount, 0)
    XCTAssertEqual(controller.recordedConnectCodes, [])
    XCTAssertEqual(controller.pendingDisconnectCount, 0)
    XCTAssertEqual(coordinator.entryCount, 0)
  }

  func testStartAppliesImmediateStatusAndConnectForwardsExactBoundedCode() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let model = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    model.start()
    await NearWireUITestWait.until { model.status?.state == .idle }
    XCTAssertEqual(model.operationPhase, .idle)
    XCTAssertEqual(model.actionPresentation, .connect(showsReset: false))

    model.updatePairingCode(String(repeating: "a", count: 64) + "DROP")
    model.performPrimaryAction()
    await NearWireUITestWait.until {
      controller.pendingConnectCount == 1 && model.operationPhase == .connecting
    }
    XCTAssertEqual(controller.recordedConnectCodes, [String(repeating: "a", count: 64)])
    XCTAssertEqual(model.actionPresentation, .cancel)

    controller.finishNextConnect()
    await NearWireUITestWait.until {
      coordinator.phase(for: controller) == .idle && model.operationPhase == .idle
        && model.pairingCode.isEmpty
    }
    model.stop()
    XCTAssertEqual(coordinator.entryCount, 0)
  }

  func testSynchronousInitialCoordinatorPhasePrecedesFirstStreamTurn() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    _ = coordinator.connect(controller: controller, code: "A") { _, _ in }
    await NearWireUITestWait.until { controller.pendingConnectCount == 1 }

    let model = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    model.start()
    XCTAssertEqual(model.operationPhase, .connecting)
    await NearWireUITestWait.until { model.status != nil }
    XCTAssertEqual(model.actionPresentation, .cancel)
    model.stop()
    controller.finishNextConnect()
    await NearWireUITestWait.until { coordinator.entryCount == 0 }
  }

  func testBackToBackConnectActivationKeepsAcceptedOriginToken() async {
    struct ExpectedFailure: Error {}

    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let model = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    model.start()
    await NearWireUITestWait.until { model.status != nil }
    model.updatePairingCode("PAIR")
    model.performPrimaryAction()
    model.performPrimaryAction()
    await NearWireUITestWait.until { controller.pendingConnectCount == 1 }
    XCTAssertEqual(controller.recordedConnectCodes, ["PAIR"])
    controller.finishNextConnect(with: .failure(ExpectedFailure()))
    await NearWireUITestWait.until { model.displayedErrorMessage != nil }
    XCTAssertEqual(
      model.displayedErrorMessage,
      "NearWire could not complete the connection action."
    )
    model.stop()
  }

  func testShutdownSuppressesActionsAcrossCoordinatorPhases() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let model = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    model.start()
    await NearWireUITestWait.until { model.status != nil }
    model.updatePairingCode("PAIR")
    model.performPrimaryAction()
    await NearWireUITestWait.until {
      model.operationPhase == .connecting && controller.pendingConnectCount == 1
    }
    controller.sendStatus(NearWireConnectionStatus(state: .shutdown))
    await NearWireUITestWait.until { model.status?.state == .shutdown }
    XCTAssertEqual(model.actionPresentation, .none)

    model.performPrimaryAction()
    XCTAssertEqual(controller.pendingDisconnectCount, 0)
    coordinator.disconnect(controller: controller)
    await NearWireUITestWait.until {
      model.operationPhase == .disconnecting && controller.pendingDisconnectCount == 1
    }
    XCTAssertEqual(model.actionPresentation, .none)
    controller.finishNextConnect()
    controller.finishNextDisconnect()
    await NearWireUITestWait.until { coordinator.phase(for: controller) == .idle }
    model.stop()
  }

  func testConservativeActionMatrixAndErrorWinner() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let model = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    model.start()
    await NearWireUITestWait.until { model.status != nil }

    for state in [NearWireState.discovering, .connecting, .connected, .reconnecting] {
      controller.sendStatus(NearWireConnectionStatus(state: state))
      await NearWireUITestWait.until { model.status?.state == state }
      XCTAssertEqual(model.actionPresentation, .disconnect)
    }
    controller.sendStatus(NearWireConnectionStatus(state: .shutdown))
    await NearWireUITestWait.until { model.status?.state == .shutdown }
    XCTAssertEqual(model.actionPresentation, .none)

    controller.sendStatus(NearWireConnectionStatus(state: .idle, isSuspended: true))
    await NearWireUITestWait.until { model.status?.isSuspended == true }
    XCTAssertEqual(model.actionPresentation, .disconnect)
    model.stop()
  }

  func testEveryDisconnectedTerminalShapeOffersConnectAndSafeReset() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let model = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    model.start()
    await NearWireUITestWait.until { model.status != nil }

    let errors = [
      NearWireError(code: .connectionClosed, message: "The connection closed."),
      NearWireError(code: .viewerRejected, message: "The Viewer rejected this App."),
      NearWireError(code: .discoveryTimedOut, message: "Viewer discovery timed out."),
    ]
    for error in errors {
      controller.sendStatus(NearWireConnectionStatus(state: .disconnected, lastError: error))
      await NearWireUITestWait.until { model.status?.lastError == error }
      XCTAssertEqual(model.actionPresentation, .connect(showsReset: true))
      XCTAssertEqual(model.displayedErrorMessage, error.message)
    }

    controller.sendStatus(NearWireConnectionStatus(state: .disconnected))
    await NearWireUITestWait.until { model.status?.lastError == nil }
    XCTAssertEqual(model.actionPresentation, .connect(showsReset: false))
    model.stop()
  }

  func testReplacementCannotStartConnectBUntilCancelledConnectAAcknowledges() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    var first: NearWireUIConnectionModel? = NearWireUIConnectionModel(
      controller: controller,
      coordinator: coordinator
    )
    weak let weakFirst = first
    first?.start()
    await NearWireUITestWait.until { first?.status != nil }
    first?.updatePairingCode("A")
    first?.performPrimaryAction()
    await NearWireUITestWait.until { controller.pendingConnectCount == 1 }
    first?.stop()
    first = nil
    XCTAssertNil(weakFirst)

    let second = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    second.start()
    await NearWireUITestWait.until { second.status != nil }
    XCTAssertEqual(second.operationPhase, .cancelling)
    second.updatePairingCode("B")
    second.performPrimaryAction()
    await Task.yield()
    XCTAssertEqual(controller.recordedConnectCodes, ["A"])

    controller.finishNextConnect()
    await NearWireUITestWait.until { second.operationPhase == .idle }
    second.performPrimaryAction()
    await NearWireUITestWait.until { controller.pendingConnectCount == 1 }
    XCTAssertEqual(controller.recordedConnectCodes, ["A", "B"])
    second.stop()
    controller.finishNextConnect()
    await NearWireUITestWait.until { coordinator.entryCount == 0 }
  }

  func testStoppingConnectedPanelDoesNotDisconnectActiveSession() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let model = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    model.start()
    await NearWireUITestWait.until { model.status != nil }
    controller.sendStatus(NearWireConnectionStatus(state: .connected))
    await NearWireUITestWait.until { model.status?.state == .connected }
    model.stop()
    XCTAssertEqual(controller.pendingDisconnectCount, 0)
    XCTAssertEqual(coordinator.entryCount, 0)
  }

  func testActionErrorWinsOverLaterHealthyStatusUntilExplicitReset() async {
    struct SecretError: Error, CustomStringConvertible {
      var description: String { "PAIRING-CODE-MUST-NOT-LEAK" }
    }

    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let model = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    model.start()
    await NearWireUITestWait.until { model.status != nil }
    model.updatePairingCode("RETAIN")
    model.performPrimaryAction()
    await NearWireUITestWait.until { controller.pendingConnectCount == 1 }
    controller.finishNextConnect(with: .failure(SecretError()))
    await NearWireUITestWait.until { model.displayedErrorMessage != nil }
    XCTAssertEqual(
      model.displayedErrorMessage,
      "NearWire could not complete the connection action."
    )
    XCTAssertEqual(model.pairingCode, "RETAIN")

    controller.sendStatus(NearWireConnectionStatus(state: .connected))
    await NearWireUITestWait.until { model.status?.state == .connected }
    XCTAssertEqual(
      model.displayedErrorMessage,
      "NearWire could not complete the connection action."
    )
    model.performPrimaryAction()
    XCTAssertNil(model.displayedErrorMessage)
    XCTAssertEqual(model.pairingCode, "")
    await NearWireUITestWait.until { controller.pendingDisconnectCount == 1 }
    controller.finishNextDisconnect()
    await NearWireUITestWait.until { coordinator.phase(for: controller) == .idle }
    model.stop()
  }

  func testHealthyStatusBeforeActionFailureStillLeavesActionErrorWinner() async {
    struct SecretError: Error, CustomStringConvertible {
      var description: String { "SECRET" }
    }

    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let model = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    model.start()
    await NearWireUITestWait.until { model.status != nil }
    model.updatePairingCode("PAIR")
    model.performPrimaryAction()
    await NearWireUITestWait.until { controller.pendingConnectCount == 1 }
    controller.sendStatus(NearWireConnectionStatus(state: .connected))
    await NearWireUITestWait.until { model.status?.state == .connected }
    controller.finishNextConnect(with: .failure(SecretError()))
    await NearWireUITestWait.until { model.displayedErrorMessage != nil }
    XCTAssertEqual(
      model.displayedErrorMessage,
      "NearWire could not complete the connection action."
    )
    model.stop()
  }

  func testOnlyOriginModelReceivesConnectActionFailure() async {
    struct ExpectedFailure: Error {}

    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let first = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    let second = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    first.start()
    second.start()
    await NearWireUITestWait.until { first.status != nil && second.status != nil }
    first.updatePairingCode("PAIR")
    first.performPrimaryAction()
    await NearWireUITestWait.until { controller.pendingConnectCount == 1 }
    controller.finishNextConnect(with: .failure(ExpectedFailure()))
    await NearWireUITestWait.until { first.displayedErrorMessage != nil }
    XCTAssertNil(second.displayedErrorMessage)
    first.stop()
    second.stop()
  }

  func testMultibyteScalarPrefixIsForwardedExactly() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let model = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    model.start()
    await NearWireUITestWait.until { model.status != nil }
    let retained = String(repeating: "a", count: 61) + "\u{4E2D}"
    model.updatePairingCode(retained + "DROP")
    model.performPrimaryAction()
    await NearWireUITestWait.until { controller.pendingConnectCount == 1 }
    XCTAssertEqual(controller.recordedConnectCodes, [retained])
    XCTAssertEqual(controller.recordedConnectCodes[0].utf8.count, 64)
    model.stop()
    controller.finishNextConnect()
    await NearWireUITestWait.until { coordinator.entryCount == 0 }
  }

  func testOwnershipFailureOffersConservativeReset() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let model = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    model.start()
    await NearWireUITestWait.until { model.status != nil }
    model.updatePairingCode("PAIR")
    model.performPrimaryAction()
    await NearWireUITestWait.until { controller.pendingConnectCount == 1 }
    controller.finishNextConnect(
      with: .failure(
        NearWireError(
          code: .connectionIntentExists,
          message: "A connection intent already exists."
        )
      )
    )
    await NearWireUITestWait.until {
      model.operationPhase == .idle
        && model.actionPresentation == .connect(showsReset: true)
    }
    XCTAssertEqual(model.actionPresentation, .connect(showsReset: true))
    model.resetConnection()
    await NearWireUITestWait.until { controller.pendingDisconnectCount == 1 }
    XCTAssertEqual(model.pairingCode, "")
    controller.finishNextDisconnect()
    await NearWireUITestWait.until { coordinator.phase(for: controller) == .idle }
    model.stop()
  }

  func testTwoModelsSharePhaseAndRemoveExactSubscriptions() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let first = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    let second = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    first.start()
    second.start()
    await NearWireUITestWait.until {
      first.status != nil && second.status != nil && controller.statusSubscriberCount == 2
    }
    XCTAssertEqual(coordinator.subscriberCount(for: controller), 2)

    first.updatePairingCode("PAIR")
    first.performPrimaryAction()
    await NearWireUITestWait.until {
      first.operationPhase == .connecting && second.operationPhase == .connecting
        && controller.pendingConnectCount == 1
    }
    XCTAssertEqual(second.actionPresentation, .cancel)

    second.stop()
    await NearWireUITestWait.until {
      coordinator.subscriberCount(for: controller) == 1 && controller.statusSubscriberCount == 1
    }
    controller.finishNextConnect()
    await NearWireUITestWait.until { coordinator.phase(for: controller) == .idle }
    first.stop()
    await NearWireUITestWait.until {
      coordinator.entryCount == 0 && controller.statusSubscriberCount == 0
    }
  }

  func testCrossPanelCancelClearsOriginAndAllowsNextConnectInBothCompletionOrders() async {
    await exerciseCrossPanelCancel(disconnectFinishesFirst: false)
    await exerciseCrossPanelCancel(disconnectFinishesFirst: true)
  }

  func testCoalescedIdleClearsRevokedOriginModelStateAndAllowsNextConnect() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let model = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    model.start()
    await NearWireUITestWait.until { model.status != nil }

    model.updatePairingCode("CANCELLED")
    model.performPrimaryAction()
    await NearWireUITestWait.until {
      controller.pendingConnectCount == 1 && model.operationPhase == .connecting
    }

    model.applyObservedPhase(.idle, retainsOrigin: false)
    XCTAssertEqual(model.operationPhase, .idle)
    XCTAssertEqual(model.pairingCode, "")

    controller.finishNextConnect()
    await NearWireUITestWait.until { coordinator.phase(for: controller) == .idle }
    model.updatePairingCode("NEXT")
    model.performPrimaryAction()
    await NearWireUITestWait.until { controller.pendingConnectCount == 1 }
    XCTAssertEqual(controller.recordedConnectCodes, ["CANCELLED", "NEXT"])

    model.stop()
    controller.finishNextConnect()
    await NearWireUITestWait.until { coordinator.entryCount == 0 }
  }

  func testReleaseWithoutStopInvalidatesObservationsAndCoordinatorRegistration() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    var model: NearWireUIConnectionModel? = NearWireUIConnectionModel(
      controller: controller,
      coordinator: coordinator
    )
    weak let weakModel = model
    model?.start()
    await NearWireUITestWait.until {
      controller.statusSubscriberCount == 1 && coordinator.subscriberCount(for: controller) == 1
    }
    model = nil
    XCTAssertNil(weakModel)
    await NearWireUITestWait.until {
      controller.statusSubscriberCount == 0 && coordinator.entryCount == 0
    }
  }

  func testReleaseDuringConnectSynchronouslyCancelsAndRemovesRegistration() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    var model: NearWireUIConnectionModel? = NearWireUIConnectionModel(
      controller: controller,
      coordinator: coordinator
    )
    weak let weakModel = model
    model?.start()
    await NearWireUITestWait.until { model?.status != nil }
    model?.updatePairingCode("PAIR")
    model?.performPrimaryAction()
    await NearWireUITestWait.until { controller.pendingConnectCount == 1 }
    model = nil

    XCTAssertNil(weakModel)
    XCTAssertEqual(coordinator.subscriberCount(for: controller), 0)
    XCTAssertEqual(coordinator.phase(for: controller), .cancelling)
    XCTAssertEqual(controller.cancellationCount, 1)
    controller.finishNextConnect()
    await NearWireUITestWait.until { coordinator.entryCount == 0 }
  }

  func testBurstReleaseLeavesNoCoordinatorRegistrationOrCleanupTaskBacklog() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    for _ in 0..<100 {
      var model: NearWireUIConnectionModel? = NearWireUIConnectionModel(
        controller: controller,
        coordinator: coordinator
      )
      model?.start()
      model = nil
      XCTAssertEqual(coordinator.entryCount, 0)
    }
    await NearWireUITestWait.until { controller.statusSubscriberCount == 0 }
    XCTAssertEqual(coordinator.entryCount, 0)
  }

  func testRepeatedStartStopUsesOneExactSubscriptionAndIgnoresStoppedStatus() async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let model = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    model.start()
    model.start()
    await NearWireUITestWait.until {
      controller.statusSubscriberCount == 1 && coordinator.subscriberCount(for: controller) == 1
    }
    model.stop()
    controller.sendStatus(NearWireConnectionStatus(state: .connected))
    await Task.yield()
    XCTAssertNil(model.status)
    XCTAssertEqual(coordinator.entryCount, 0)

    model.start()
    await NearWireUITestWait.until { model.status?.state == .connected }
    XCTAssertEqual(controller.statusSubscriberCount, 1)
    XCTAssertEqual(coordinator.subscriberCount(for: controller), 1)
    model.stop()
    await NearWireUITestWait.until { controller.statusSubscriberCount == 0 }
  }

  func testDistinctControllerReplacementRejectsOldYieldsAndTargetsOnlyNewController() async {
    let oldController = NearWireUIFakeController()
    let newController = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    var oldModel: NearWireUIConnectionModel? = NearWireUIConnectionModel(
      controller: oldController,
      coordinator: coordinator
    )
    weak let weakOldModel = oldModel
    oldModel?.start()
    await NearWireUITestWait.until { oldModel?.status != nil }
    oldModel?.updatePairingCode("OLD")
    oldModel?.performPrimaryAction()
    await NearWireUITestWait.until { oldController.pendingConnectCount == 1 }

    oldModel?.stop()
    oldModel = nil
    XCTAssertNil(weakOldModel)

    let newModel = NearWireUIConnectionModel(
      controller: newController,
      coordinator: coordinator
    )
    newModel.start()
    await NearWireUITestWait.until { newModel.status?.state == .idle }
    oldController.sendStatus(NearWireConnectionStatus(state: .shutdown))
    oldController.finishNextConnect(
      with: .failure(
        NearWireError(code: .viewerRejected, message: "Old controller failure.")
      )
    )
    await NearWireUITestWait.until { coordinator.phase(for: oldController) == .idle }
    XCTAssertEqual(newModel.status?.state, .idle)
    XCTAssertNil(newModel.displayedErrorMessage)

    newModel.updatePairingCode("NEW")
    newModel.performPrimaryAction()
    await NearWireUITestWait.until { newController.pendingConnectCount == 1 }
    XCTAssertEqual(oldController.recordedConnectCodes, ["OLD"])
    XCTAssertEqual(newController.recordedConnectCodes, ["NEW"])
    newController.finishNextConnect()
    await NearWireUITestWait.until { coordinator.phase(for: newController) == .idle }
    newModel.stop()
  }

  private func exerciseCrossPanelCancel(disconnectFinishesFirst: Bool) async {
    let controller = NearWireUIFakeController()
    let coordinator = NearWireUIOperationCoordinator()
    let origin = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    let peer = NearWireUIConnectionModel(controller: controller, coordinator: coordinator)
    origin.start()
    peer.start()
    await NearWireUITestWait.until { origin.status != nil && peer.status != nil }

    origin.updatePairingCode("FIRST")
    origin.performPrimaryAction()
    await NearWireUITestWait.until {
      origin.operationPhase == .connecting && peer.operationPhase == .connecting
        && controller.pendingConnectCount == 1
    }
    peer.performPrimaryAction()
    await NearWireUITestWait.until {
      origin.operationPhase == .disconnecting && peer.operationPhase == .disconnecting
        && controller.pendingDisconnectCount == 1
    }
    XCTAssertEqual(origin.pairingCode, "")
    XCTAssertEqual(origin.actionPresentation, .disconnecting)

    if disconnectFinishesFirst {
      controller.finishNextDisconnect()
      await NearWireUITestWait.until { origin.operationPhase == .disconnecting }
      controller.finishNextConnect()
    } else {
      controller.finishNextConnect()
      await NearWireUITestWait.until { origin.operationPhase == .disconnecting }
      controller.finishNextDisconnect()
    }
    await NearWireUITestWait.until {
      origin.operationPhase == .idle && peer.operationPhase == .idle
    }

    origin.updatePairingCode("NEXT")
    origin.performPrimaryAction()
    await NearWireUITestWait.until { controller.pendingConnectCount == 1 }
    XCTAssertEqual(controller.recordedConnectCodes, ["FIRST", "NEXT"])
    origin.stop()
    peer.stop()
    controller.finishNextConnect()
    await NearWireUITestWait.until { coordinator.entryCount == 0 }
  }
}
