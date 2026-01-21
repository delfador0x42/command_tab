@available(iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0, watchOS 10.0, *)
struct $s17KeyboardShortcuts0019Recorderswift_DJEEdfMX171_0_33_98CBDE15825535FCDCA8FA1A56B1564ALl7PreviewfMf_15PreviewRegistryfMu_: DeveloperToolsSupport.PreviewRegistry {
    static var fileID: String {
        "KeyboardShortcuts/Recorder.swift"
    }
    static var line: Int {
        172
    }
    static var column: Int {
        1
    }

    static func makePreview() throws -> DeveloperToolsSupport.Preview {
        DeveloperToolsSupport.Preview {
            func __b_buildView(@SwiftUI.ViewBuilder body: () -> any SwiftUI.View) -> any SwiftUI.View {
                body()
            }
            return __b_buildView {
            	KeyboardShortcuts.Recorder("record_shortcut", name: .init("xcodePreview"))
            		.environment(\.locale, .init(identifier: "en"))
            }
        }
    }
}

// original-source-range: /Users/tal/Library/Developer/Xcode/DerivedData/command_tab-cbvztjirnwxujggeddzivdileebr/SourcePackages/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Recorder.swift:172:1-175:2
