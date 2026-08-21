//
//  MediaBrowserApp.swift
//  MediaBrowser
//
//  Created by Nils Hein on 21/8/26.
//

import SwiftUI

@main
struct MediaBrowserApp: App {
    @State private var model = BrowserModel()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(model)
        }
        .commands {
            // Grid column shortcuts as real menu items (spec section 9) so the
            // Cmd-1...Cmd-4 accelerators work regardless of keyboard focus.
            CommandGroup(after: .toolbar) {
                Section {
                    ForEach(1...4, id: \.self) { count in
                        Button("\(count) Column\(count == 1 ? "" : "s")") {
                            model.gridColumns = count
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(count)")), modifiers: .command)
                    }
                }
            }
        }
    }
}
