//
//  PriceViewModel.swift
//  CSAI1
//
//  Updated by ChatGPT on 2025-06-07 to enable live WebSocket updates and fix historical URL builder
//

import Foundation
import Combine
import SwiftUI

// MARK: - ChartTimeframe Definition
enum ChartTimeframe {
    case oneMinute, fiveMinutes, fifteenMinutes, thirtyMinutes
    case oneHour, fourHours, oneDay, oneWeek, oneMonth, threeMonths
    case oneYear, threeYears, allTime
    case live
}

struct BinancePriceResponse: Codable {
    let price: String
}

struct CoinGeckoPriceResponse: Codable {
    let usd: Double
}

struct PriceChartResponse: Codable {
    let prices: [[Double]]
}

@MainActor
class PriceViewModel: ObservableObject {
    // Shared URLSession with custom timeout
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
    
    @Published var price: Double = 0
    @Published var symbol: String
    @Published var historicalData: [ChartDataPoint] = []
    @Published var liveData: [ChartDataPoint] = []
    @Published var timeframe: ChartTimeframe
    
    private let service = CryptoAPIService.shared
    // WebSocket-based price publisher service
    private let wsService: PriceService = BinanceWebSocketPriceService()
    private var liveCancellable: AnyCancellable?
    
    private var pollingTask: Task<Void, Never>?
    private let maxBackoff: Double = 60.0
    
    init(symbol: String, timeframe: ChartTimeframe = .live) {
        self.symbol = symbol
        self.timeframe = timeframe
        if timeframe == .live {
            let id = coingeckoID(for: symbol)
            startLiveUpdates(coinID: id)
        } else {
            startPolling()
        }
    }
    
    func updateSymbol(_ newSymbol: String) {
        symbol = newSymbol
        stopPolling()
        stopLiveUpdates()
        if timeframe == .live {
            let id = coingeckoID(for: newSymbol)
            startLiveUpdates(coinID: id)
        } else {
            startPolling()
        }
    }
    
    func updateTimeframe(_ newTimeframe: ChartTimeframe) {
        guard newTimeframe != timeframe else { return }
        timeframe = newTimeframe
        if newTimeframe == .live {
            stopPolling()
            let id = coingeckoID(for: symbol)
            startLiveUpdates(coinID: id)
        } else {
            stopLiveUpdates()
            startPolling()
        }
    }
    
    // MARK: - REST Polling with Backoff
    func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self = self else { return }
            // Immediate initial fetch
            if let initial = await self.fetchPriceChain(for: self.symbol) {
                await MainActor.run {
                    withAnimation(.linear(duration: 0.2)) {
                        self.price = initial
                    }
                }
            }
            // Start backoff loop
            var delay: Double = 5
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if let newPrice = await self.fetchPriceChain(for: self.symbol) {
                    await MainActor.run {
                        withAnimation(.linear(duration: 0.2)) {
                            self.price = newPrice
                        }
                    }
                    delay = 5
                } else {
                    delay = min(self.maxBackoff, delay * 2)
                }
            }
        }
    }
    
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
    
    // 3-step fallback: CryptoAPIService → Binance → CoinGecko
    private func fetchPriceChain(for symbol: String) async -> Double? {
        if let p = try? await service.fetchSpotPrice(coin: symbol) {
            return p
        }
        if let p = await fetchBinancePrice(for: symbol) {
            return p
        }
        return await fetchCoingeckoPrice(for: symbol)
    }
    
    private func fetchBinancePrice(for symbol: String) async -> Double? {
        let pair = symbol.uppercased() + "USDT"
        guard let url = URL(string: "https://api.binance.com/api/v3/ticker/price?symbol=\(pair)") else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            let decoded = try JSONDecoder().decode(BinancePriceResponse.self, from: data)
            return Double(decoded.price)
        } catch {
            return nil
        }
    }
    
    /// Map ticker symbols to CoinGecko IDs using the shared LivePriceManager map
    private func coingeckoID(for symbol: String) -> String {
        let lower = symbol.lowercased()
        return LivePriceManager.shared.geckoIDMap[lower] ?? lower
    }
    
    private func fetchCoingeckoPrice(for symbol: String) async -> Double? {
        let id = coingeckoID(for: symbol)
        var comps = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")
        comps?.queryItems = [
            URLQueryItem(name: "ids", value: id),
            URLQueryItem(name: "vs_currencies", value: "usd")
        ]
        guard let url = comps?.url else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            let dict = try JSONDecoder().decode([String: CoinGeckoPriceResponse].self, from: data)
            return dict[id]?.usd
        } catch {
            return nil
        }
    }
    
    // MARK: - Live WebSocket Updates
    func startLiveUpdates(coinID: String) {
        // initial fallback fetch before socket data arrives
        Task { [weak self] in
            guard let self = self else { return }
            if let initial = await self.fetchPriceChain(for: self.symbol) {
                await MainActor.run {
                    withAnimation(.linear(duration: 0.2)) {
                        self.price = initial
                    }
                }
            }
        }
        liveData.removeAll()
        // Open WebSocket for real-time updates
        // Removed LivePriceManager.shared.connect(symbol: coinID)
        // subscribe to WebSocket price updates for the given coin ID
        liveCancellable = wsService.pricePublisher(for: [coinID], interval: 0)
            .compactMap { $0[coinID] }
            .map { ChartDataPoint(date: Date(), close: $0, volume: 0) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] point in
                guard let self = self else { return }
                self.liveData.append(point)
                if self.liveData.count > 60 {
                    self.liveData.removeFirst(self.liveData.count - 60)
                }
                withAnimation(.linear(duration: 0.2)) {
                    self.price = point.close
                }
            }
    }
    
    func stopLiveUpdates() {
        liveCancellable?.cancel()
        liveCancellable = nil
    }
    
    // MARK: - Historical Chart
    func fetchHistoricalData(for coinID: String, timeframe: ChartTimeframe) async {
        guard let url = CryptoAPIService.buildPriceHistoryURL(for: coinID, timeframe: timeframe) else { return }
        do {
            let (data, _) = try await session.data(from: url)
            let decoded = try JSONDecoder().decode(PriceChartResponse.self, from: data)
            let points = decoded.prices.map { arr in
                ChartDataPoint(date: Date(timeIntervalSince1970: arr[0] / 1000), close: arr[1], volume: 0)
            }
            self.historicalData = points
        } catch {
            // handle error
        }
    }
}
