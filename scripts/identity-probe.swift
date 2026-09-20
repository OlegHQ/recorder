import Foundation
import CoreServices
import UniformTypeIdentifiers

@main struct IdentityProbe {
    static func main() {
        print("bundle", Bundle.main.bundleIdentifier ?? "nil")
        print("registration", LSRegisterURL(Bundle.main.bundleURL as CFURL, true))
        for type in AppIdentity.projectTypes {
            print("type", type.identifier, "declared", type.isDeclared, "package", type.conforms(to: .package))
        }
        print("exported", Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") ?? "nil")
        print("imported", Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") ?? "nil")
    }
}
