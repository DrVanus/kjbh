//
//  PriceService.swift
//  CryptoSage
//
//  Created by DM on 5/28/25.
//


import Combine
import Foundation

/// Protocol for services that publish live price updates for given symbols.
protocol PriceService {
    func pricePublisher(
        for symbols: [String],
        interval: TimeInterval
    ) -> AnyPublisher<[String: Double], Never>
}

/// Live implementation using Binance WebSocket for real-time price updates.
/// Currently falls back to CoinGecko polling until WebSocket logic is finalized.
final class BinanceWebSocketPriceService: PriceService {
    private let fallback = CoinGeckoPriceService()
    
    func pricePublisher(
        for symbols: [String],
        interval: TimeInterval
    ) -> AnyPublisher<[String: Double], Never> {
        // TODO: wire up actual WebSocket here
        return fallback.pricePublisher(for: symbols, interval: interval)
    }
}

/// Live implementation using CoinGecko's simple price API to emit up-to-date prices.
final class CoinGeckoPriceService: PriceService {
    func pricePublisher(
        for symbols: [String],
        interval: TimeInterval
    ) -> AnyPublisher<[String: Double], Never> {
        let pollInterval = interval > 0 ? interval : 5.0

        // Build comma-separated CoinGecko IDs from symbols
        let idList = symbols
            .map { LivePriceManager.shared.geckoIDMap[$0.lowercased()] ?? $0.lowercased() }
            .joined(separator: ",")
        
        // Construct URL
        guard let url = URL(
            string: "https://api.coingecko.com/api/v3/simple/price" +
                    "?ids=\(idList)&vs_currencies=usd"
        ) else {
            return Just([:]).eraseToAnyPublisher()
        }
        
        let timer = Timer.publish(every: pollInterval, on: .main, in: .common)
            .autoconnect()
            .prepend(Date())
        
        return timer
            .flatMap { _ in
                URLSession.shared.dataTaskPublisher(for: url)
                    .map(\.data)
                    .decode(type: [String: [String: Double]].self, decoder: JSONDecoder())
                    .map { dict in dict.compactMapValues { $0["usd"] } }
                    .replaceError(with: [:])
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
}
