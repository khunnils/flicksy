//
//  GridSizePicker.swift
//  MediaBrowser
//

import SwiftUI

/// Segmented control for choosing the grid column count (spec section 9).
struct GridSizePicker: View {
    @Binding var columns: Int

    var body: some View {
        Picker("Grid size", selection: $columns) {
            ForEach(1...4, id: \.self) { count in
                Text("\(count)×\(count)").tag(count)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Change the number of grid columns")
    }
}
