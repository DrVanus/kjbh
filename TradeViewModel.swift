import SwiftUI
import Combine
import WebKit

struct TradingViewWebView: UIViewRepresentable {
    let symbol: String   // e.g. "BINANCE:BTCUSDT"
    let interval: String // e.g. "D" for daily, "15" for 15m, etc.
    let theme: String    // "Dark" or "Light"
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.scrollView.isScrollEnabled = false // Prevent scrolling inside the chart
        webView.backgroundColor = .clear
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        let htmlString = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                body, html { margin: 0; padding: 0; background: transparent; }
            </style>
        </head>
        <body>
            <div class="tradingview-widget-container">
                <div id="tv_chart_container"></div>
                <script type="text/javascript" src="https://s3.tradingview.com/tv.js"></script>
                <script type="text/javascript">
                    new TradingView.widget({
                        "autosize": true,
                        "symbol": "\(symbol)",
                        "interval": "\(interval)",
                        "timezone": "Etc/UTC",
                        "theme": "\(theme)",
                        "style": "1",
                        "locale": "en",
                        "toolbar_bg": "#f1f3f6",
                        "enable_publishing": false,
                        "allow_symbol_change": true,
                        "container_id": "tv_chart_container"
                    });
                </script>
            </div>
        </body>
        </html>
        """
        uiView.loadHTMLString(htmlString, baseURL: nil)
    }
}


class TradeViewModel: ObservableObject {
    @Published var currentSymbol: String
    @Published var currentPrice: Double = 0.0
    @Published var balance: Double = 0.0
    private var cancellables = Set<AnyCancellable>()

    init(symbol: String) {
        self.currentSymbol = symbol
        fetchCurrentPrice()
        fetchBalance(for: symbol)
        Timer.publish(every: 10, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.fetchCurrentPrice() }
            .store(in: &cancellables)
        // react to symbol changes
        $currentSymbol
            .removeDuplicates()
            .sink { [weak self] newSymbol in
                self?.fetchCurrentPrice()
                self?.fetchBalance(for: newSymbol)
            }
            .store(in: &cancellables)
    }

    // map ticker symbol to CoinGecko ID
    private var coinID: String {
        switch currentSymbol.uppercased() {
        case "BTC": return "bitcoin"
        case "ETH": return "ethereum"
        // add other mappings as needed
        default: return currentSymbol.lowercased()
        }
    }

    private func fetchCurrentPrice() {
        Task {
            do {
                let price = try await CryptoAPIService.shared.fetchSpotPrice(coin: coinID)
                await MainActor.run {
                    self.currentPrice = price
                }
            } catch {
                print("Failed to fetch price:", error)
            }
        }
    }

    /// Placeholder balance fetcher — replace with real API integration.
    func fetchBalance(for symbol: String) {
        // TODO: integrate real wallet or account balance API
        DispatchQueue.main.async {
            self.balance = 0.0
        }
    }

    /// Decrement a typed quantity by 1, clamped at 0.
    func decrementQuantity(_ quantityString: inout String) {
        let value = max(0, (Double(quantityString) ?? 0) - 1)
        quantityString = String(format: "%.4f", value)
    }

    /// Increment a typed quantity by 1.
    func incrementQuantity(_ quantityString: inout String) {
        let value = (Double(quantityString) ?? 0) + 1
        quantityString = String(format: "%.4f", value)
    }

    /// Fill the order quantity based on a percentage of current balance.
    func fillQuantity(forPercent percent: Int) -> String {
        let qty = balance * Double(percent) / 100.0
        return String(format: "%.4f", qty)
    }

    /// Execute a trade (placeholder) — wire up to real execution API.
    func executeTrade(side: TradeSide, symbol: String, orderType: OrderType, quantity: String) {
        // TODO: call your trading execution service
        print("Executing \(side.rawValue) \(quantity) of \(symbol) as \(orderType.rawValue)")
    }
}
