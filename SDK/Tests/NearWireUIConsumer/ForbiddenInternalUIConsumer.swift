import NearWire
import NearWireUI

func compileForbiddenInternalUIAPI() {
  _ = NearWireUIConnectionModel.self
  _ = NearWireUIConnectionControlling.self
  _ = NearWireUIInputLimiter.self
  _ = NearWireUIStatusPresentation.self
  _ = NearWireUIOperationCoordinator.self
  _ = NearWireConnectionContent.self
}
