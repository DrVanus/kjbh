//
//  PriceView.swift
//  CryptoSage
//
//  Created by DM on 7/17/25.
//


import SwiftUI

struct PriceView: View {
    @ObservedObject var viewModel: PriceViewModel

    init(symbol: String) {
        _viewModel = ObservedObject(wrappedValue:
            PriceViewModel(symbol: symbol, timeframe: .live)
        )
    }

    var body: some View {
        VStack {
            Text("$\(viewModel.price, specifier: "%.2f")")
                .font(.largeTitle)
                .bold()
                // Optional: animate changes
                .animation(.easeInOut(duration: 0.2), value: viewModel.price)

            // …any other UI…
        }
    }
}

// Preview
struct PriceView_Previews: PreviewProvider {
    static var previews: some View {
        PriceView(symbol: "BTC")
    }
}
