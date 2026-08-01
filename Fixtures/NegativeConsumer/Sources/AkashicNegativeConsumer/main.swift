import AkashicCore
import AkashicDisk
import Foundation

// This fixture must not compile outside the Akashic package boundary.
let point = FileBlobStoreSwitchPoint.afterManifestPublished
let root = FileManager.default.temporaryDirectory
_ = try await FileBlobStore.open(
    root: root,
    faultInjector: { observed in
        precondition(observed == point)
    }
)
