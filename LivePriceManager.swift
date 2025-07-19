import Foundation
import Combine

final class LivePriceManager {
    static let shared = LivePriceManager()

    // Map from ticker symbol to CoinGecko ID
    var geckoIDMap: [String: String] = [
        "btc": "bitcoin", "eth": "ethereum", "bnb": "binancecoin",
        "usdt": "tether",
        "busd": "binance-usd", "usdc": "usd-coin", "sol": "solana",
        "ada": "cardano", "xrp": "ripple", "doge": "dogecoin",
        "dot": "polkadot", "avax": "avalanche-2", "matic": "matic-network",
        "link": "chainlink", "xlm": "stellar", "bch": "bitcoin-cash",
        "trx": "tron", "uni": "uniswap", "etc": "ethereum-classic",
        "wbtc": "wrapped-bitcoin", "steth": "staked-ether",
        "wsteth": "wrapped-steth", "sui": "sui", "hype": "hyperliquid",
        "leo": "leo-token", "fil": "filecoin"
    ]

    // Timer for polling
    var timer: Timer?

    // Subject to broadcast price dictionaries
    private let priceSubject = PassthroughSubject<[String: Double], Never>()
    var pricePublisher: AnyPublisher<[String: Double], Never> {
        priceSubject.eraseToAnyPublisher()
    }

    /// Alias for the internal pricePublisher so subscribers can use `.publisher`
    var publisher: AnyPublisher<[String: Double], Never> {
        pricePublisher
    }

    // Start polling CoinGecko for simple price updates
    func startPolling(ids: [String], interval: TimeInterval = 5) {
        stopPolling()
        fetchPrices(for: ids)
        // Use a timer added to the common run loop to ensure it fires during UI updates
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetchPrices(for: ids)
        }
        timer = newTimer
        RunLoop.main.add(newTimer, forMode: .common)
    }

    // Stop the polling timer
    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// Start a live feed for a single symbol using polling
    func connect(symbol: String, interval: TimeInterval = 5) {
        // Normalize symbol by removing USDT suffix if present
        let lower = symbol.lowercased()
        let clean = lower.hasSuffix("usdt") ? String(lower.dropLast(4)) : lower
        // Map to CoinGecko ID and begin polling
        let id = geckoIDMap[clean] ?? clean
        startPolling(ids: [id], interval: interval)
    }

    /// Stop the live feed
    func disconnect() {
        stopPolling()
    }

    // Fetch current prices for given symbols and send through the subject
    private func fetchPrices(for symbols: [String]) {
        print("LivePriceManager: fetchPrices called for symbols: \(symbols)")
        let idList = symbols
            .map { geckoIDMap[$0.lowercased()] ?? $0.lowercased() }
            .joined(separator: ",")
        guard let url = URL(string:
            "https://api.coingecko.com/api/v3/simple/price?ids=\(idList)&vs_currencies=usd"
        ) else { return }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let dict = try? JSONDecoder().decode([String: [String: Double]].self, from: data)
            else { return }

            print("LivePriceManager: fetched raw dict: \(dict)")

            // Extract USD prices and broadcast
            let result = dict.compactMapValues { $0["usd"] }
            DispatchQueue.main.async {
                print("LivePriceManager: sending result to subject: \(result)")
                self.priceSubject.send(result)
            }
        }.resume()
    }
}
